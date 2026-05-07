# ============================================================
# prepare parquet table instead of maps.R
#
# Pre-extracts all 6,591 species rasters into one compressed
# Parquet file for fast downstream queries — replacing the
# need to load individual .tif files at analysis time.
#
# Run once whenever maps are updated. Requires ~2–4 GB RAM.
#
# Output columns:
#   species      — species name (from filename)
#   lon, lat     — pixel centre coordinates
#   present_now  — 0/1 from Presence-absence (unmasked)
#   present_ssp2 — 0-5 from Future/SSP2 (unmasked)
#   present_ssp3 — 0-5 from Future/SSP3 (unmasked)
#   within_hull  — TRUE if pixel is within the convex hull
#                  (derived from Presence-absence masked by hull)
#
# Only pixels where (present in any scenario) OR (within hull)
# are stored. All-absent, out-of-hull pixels are dropped.
# ============================================================

# load packages
library(terra)
library(data.table)
library(arrow)
library(parallel)
library(dplyr)
library(duckdb)

# ---- helper: format seconds to readable time ---------------
format_time <- function(secs) {
  secs <- round(secs)
  if (secs < 60)   return(sprintf("%ds", secs))
  if (secs < 3600) return(sprintf("%dm%02ds", secs %/% 60, secs %% 60))
  sprintf("%dh%02dm", secs %/% 3600, (secs %% 3600) %/% 60)
}

# ---- paths -------------------------------------------------
base_maps <- "C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/Maps"

dir_now  <- file.path(base_maps, "Presence-absence")
dir_hull <- file.path(base_maps, "Presence-absence masked by hull")
dir_ssp2 <- file.path(base_maps, "Future/SSP2")
dir_ssp3 <- file.path(base_maps, "Future/SSP3")

out_parquet <- file.path(dirname(base_maps), "species_presence.parquet")
chunk_dir   <- file.path(dirname(base_maps), "parquet_chunks")
dir.create(chunk_dir, showWarnings = FALSE)

# ---- species list ------------------------------------------
dir_sp <- "C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/Maps/Future masked by hull/SSP3"
species_files <- list.files(dir_sp, pattern = "\\.tif$", full.names = FALSE)
n_species     <- length(species_files)
cat(sprintf("Found %d species. Output: %s\n\n", n_species, out_parquet))

# check file lists across directories
files_now  <- list.files(dir_now,  pattern = "\\.tif$", full.names = FALSE)
files_hull <- list.files(dir_hull, pattern = "\\.tif$", full.names = FALSE)
files_ssp2 <- list.files(dir_ssp2, pattern = "\\.tif$", full.names = FALSE)
files_ssp3 <- list.files(dir_sp,   pattern = "\\.tif$", full.names = FALSE)

# species missing from any directory as compared to dir_sp
all_sp <- Reduce(union, list(files_now, files_hull, files_ssp2, files_ssp3))
cat("Only in now :", sum(!files_now  %in% files_ssp3), "\n")
cat("Only in hull:", sum(!files_hull %in% files_ssp3), "\n")
cat("Only in ssp2:", sum(!files_ssp2 %in% files_ssp3), "\n")
cat("Missing from now :", sum(!files_ssp3 %in% files_now),  "\n")
cat("Missing from hull:", sum(!files_ssp3 %in% files_hull), "\n")
cat("Missing from ssp2:", sum(!files_ssp2 %in% files_ssp3), "\n")

# ---- per-species function (runs on each worker) ------------
process_species <- function(fname) {
  
  sp_name <- tools::file_path_sans_ext(fname)
  
  paths <- c(
    now  = file.path(dir_now,  fname),
    hull = file.path(dir_hull, fname),
    ssp2 = file.path(dir_ssp2, fname),
    ssp3 = file.path(dir_ssp3, fname)
  )
  
  # skip if any file missing
  missing <- paths[!file.exists(paths)]
  if (length(missing) > 0) {
    if (length(missing) < 4)
      warning(sprintf("Skipping '%s' — missing: %s",
                      sp_name, paste(names(missing), collapse = ", ")))
    return(NULL)
  }
  
  # read all four rasters
  r_now  <- rast(paths["now"])
  r_hull <- rast(paths["hull"])
  r_ssp2 <- rast(paths["ssp2"])
  r_ssp3 <- rast(paths["ssp3"])
  
  # crop r_now to shared extent (hull/ssp2/ssp3 are consistent)
  r_now <- crop(r_now, ext(r_hull))
  
  # stack
  stk <- tryCatch(
    c(r_now, r_hull, r_ssp2, r_ssp3),
    error = function(e) {
      warning(sprintf("Cannot stack '%s': %s", sp_name, conditionMessage(e)))
      NULL
    }
  )
  if (is.null(stk)) return(NULL)
  
  names(stk) <- c("present_now", "hull_val", "present_ssp2", "present_ssp3")
  
  # extract values
  vals <- values(stk)
  
  # keep pixels present in any scenario OR within hull
  keep <- (!is.na(vals[, "present_now"])  & vals[, "present_now"]  == 1L) |
    (!is.na(vals[, "hull_val"]))                                      |
    (!is.na(vals[, "present_ssp2"]) & vals[, "present_ssp2"] == 1L) |
    (!is.na(vals[, "present_ssp3"]) & vals[, "present_ssp3"] == 1L)
  
  if (!any(keep)) return(NULL)
  
  # compute coords from cropped r_now (grid changed after crop)
  coords_sp <- xyFromCell(r_now, 1:ncell(r_now))
  
  data.table(
    species      = sp_name,
    lon          = coords_sp[keep, 1],
    lat          = coords_sp[keep, 2],
    present_now  = as.integer(vals[keep, "present_now"]),
    present_ssp2 = as.integer(vals[keep, "present_ssp2"]),
    present_ssp3 = as.integer(vals[keep, "present_ssp3"]),
    within_hull  = !is.na(vals[keep, "hull_val"])
  )
}

# ---- parallel setup ----------------------------------------
n_cores <- max(1, detectCores() - 6)
cat(sprintf("Using %d cores\n\n", n_cores))

cl <- makeCluster(n_cores)
clusterExport(cl, c("dir_now", "dir_hull", "dir_ssp2", "dir_ssp3"))
clusterEvalQ(cl, { library(terra); library(data.table) })

# ---- process in chunks of 500 to keep RAM manageable -------
chunk_size  <- 500
chunk_files <- split(species_files, ceiling(seq_along(species_files) / chunk_size))
n_chunks    <- length(chunk_files)
skipped     <- character(0)
t_start     <- proc.time()

for (ch in seq_along(chunk_files)) {
  
  cat(sprintf("Chunk %d/%d — %d species...\n", ch, n_chunks, length(chunk_files[[ch]])))
  
  # run in parallel
  chunk_results <- parLapply(cl, chunk_files[[ch]], process_species)
  
  # track skipped
  skipped <- c(skipped, chunk_files[[ch]][sapply(chunk_results, is.null)])
  
  # bind and write chunk parquet
  chunk_results <- chunk_results[!sapply(chunk_results, is.null)]
  if (length(chunk_results) > 0) {
    dt_chunk <- rbindlist(chunk_results, use.names = TRUE, fill = TRUE)
    dt_chunk[, present_now  := as.integer(present_now)]
    dt_chunk[, present_ssp2 := as.integer(present_ssp2)]
    dt_chunk[, present_ssp3 := as.integer(present_ssp3)]
    dt_chunk[, within_hull  := as.logical(within_hull)]
    chunk_path <- file.path(chunk_dir, sprintf("chunk_%03d.parquet", ch))
    write_parquet(dt_chunk, chunk_path, compression = "snappy")
    rm(dt_chunk, chunk_results)
    gc()
  }
  
  elapsed <- (proc.time() - t_start)[["elapsed"]]
  eta     <- elapsed / ch * (n_chunks - ch)
  cat(sprintf("  done — elapsed %s  ETA %s\n", format_time(elapsed), format_time(eta)))
}

stopCluster(cl)

# ---- check chunks written ----------------------------------
cat(sprintf("\nChunks written: %d\n", length(list.files(chunk_dir, pattern = "\\.parquet$"))))

# ---- merge all chunks into one parquet ---------------------
cat("Merging chunks...\n")

chunk_paths <- list.files(chunk_dir, pattern = "\\.parquet$", full.names = TRUE)
if (length(chunk_paths) == 0) stop("No chunk files found — check that chunk writing succeeded above")

# connect to in-memory duckdb instance
con <- dbConnect(duckdb())

# merge all parquet chunks into one file
dbExecute(con, "
  COPY (
    SELECT * FROM read_parquet('C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/parquet_chunks/*.parquet')
  )
  TO 'C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/D4N_merged.parquet'
  (FORMAT PARQUET)
")

dbDisconnect(con)

# # read all chunks and write as single parquet file
# ds    <- open_dataset(chunk_dir, format = "parquet")
# dt_all <- as.data.table(ds)
# write_parquet(dt_all, out_parquet, compression = "snappy")
# rm(dt_all); gc()

if (length(skipped) > 0) {
  cat(sprintf("Skipped: %d species (files absent or mismatched)\n", length(skipped)))
}

# read parquet into dataframe # gives memory error
# df <- read_parquet("C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/D4N_merged.parquet")

# get suitable species at a given coordinate using duckdb

# target coordinate
target_lon <- -74
target_lat <- 5

con <- dbConnect(duckdb())

# find species present at the nearest grid point, no full table load
species_here <- dbGetQuery(con, sprintf("
  WITH closest AS (
    SELECT lon, lat
    FROM read_parquet('C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/D4N_merged.parquet')
    ORDER BY ((lon - %f)^2 + (lat - %f)^2)
    LIMIT 1
  )
  SELECT DISTINCT species
  FROM read_parquet('C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/D4N_merged.parquet')
  WHERE present_now = 1
    AND lon = (SELECT lon FROM closest)
    AND lat = (SELECT lat FROM closest)
", target_lon, target_lat))

dbDisconnect(con)

# clean vector of species names
species_vec <- species_here$species





