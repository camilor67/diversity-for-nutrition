# ============================================================
# prepare parquet table instead of maps.R
#
# Pre-extracts all species rasters into one compressed
# Parquet file for fast downstream queries — replacing the
# need to load individual .tif files at analysis time.
#
# Run once whenever maps are updated. Requires ~2–4 GB RAM.
#
# Output columns:
#   species      — species name (from filename)
#   lon, lat     — pixel centre coordinates
#   present_now  — 0/1 from Presence-absence (unmasked)
#                  NA where the future maps have no data (temporary,
#                  until present and future land masks match)
#   present_ssp2 — 0-5 from Future/SSP2 (unmasked)
#   present_ssp3 — 0-5 from Future/SSP3 (unmasked)
#                  species without future maps: present_now * 5
#   within_hull  — TRUE if pixel is within the convex hull
#                  (derived from Presence-absence masked by hull)
#   has_future   — FALSE if future values were filled from present
#
# Only pixels where (present in any scenario) OR (within hull)
# are stored. All-absent, out-of-hull pixels are dropped.
# Rows are sorted by lat, lon, species for fast location queries.
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

# written under a separate name; rename to D4N_maps.parquet manually after checking
out_parquet <- file.path(dirname(base_maps), "D4N_merged.parquet")
chunk_dir   <- file.path(dirname(base_maps), "parquet_chunks")

# start from an empty chunk dir so stale chunks aren't merged
unlink(chunk_dir, recursive = TRUE)
dir.create(chunk_dir, showWarnings = FALSE)

# ---- species list (all species with a present map) ---------
files_now  <- list.files(dir_now,  pattern = "\\.tif$", full.names = FALSE)
files_hull <- list.files(dir_hull, pattern = "\\.tif$", full.names = FALSE)
files_ssp2 <- list.files(dir_ssp2, pattern = "\\.tif$", full.names = FALSE)
files_ssp3 <- list.files(dir_ssp3, pattern = "\\.tif$", full.names = FALSE)

species_files <- files_now
n_species     <- length(species_files)
cat(sprintf("Found %d species. Output: %s\n\n", n_species, out_parquet))

# check file lists across directories
cat("Present without hull map  :", sum(!files_now %in% files_hull), "(will be skipped)\n")
cat("Present without SSP2 map  :", sum(!files_now %in% files_ssp2), "(filled from present)\n")
cat("Present without SSP3 map  :", sum(!files_now %in% files_ssp3), "(filled from present)\n")
cat("SSP2 map without present  :", sum(!files_ssp2 %in% files_now), "(ignored)\n")
cat("SSP3 map without present  :", sum(!files_ssp3 %in% files_now), "(ignored)\n")
cat("SSP2 and SSP3 sets differ :", length(setdiff(union(files_ssp2, files_ssp3), intersect(files_ssp2, files_ssp3))), "\n\n")

# future land mask for species without future maps (same for all species)
ref_future <- file.path(dir_ssp2, files_ssp2[1])

# ---- per-species function (runs on each worker) ------------
process_species <- function(fname) {
  
  sp_name <- tools::file_path_sans_ext(fname)
  
  paths <- c(
    now  = file.path(dir_now,  fname),
    hull = file.path(dir_hull, fname),
    ssp2 = file.path(dir_ssp2, fname),
    ssp3 = file.path(dir_ssp3, fname)
  )
  
  # present and hull maps are required; future maps are optional
  if (!file.exists(paths["now"]) || !file.exists(paths["hull"])) return(NULL)
  has_ssp2   <- file.exists(paths["ssp2"])
  has_ssp3   <- file.exists(paths["ssp3"])
  has_future <- has_ssp2 && has_ssp3

  r_now  <- rast(paths["now"])
  r_hull <- rast(paths["hull"])

  # crop r_now to shared extent (hull/ssp2/ssp3 are consistent)
  r_now <- crop(r_now, ext(r_hull))

  # stack only the maps that exist
  layers <- list(present_now = r_now, hull_val = r_hull)
  if (has_ssp2) layers$present_ssp2 <- rast(paths["ssp2"])
  if (has_ssp3) layers$present_ssp3 <- rast(paths["ssp3"])
  stk <- tryCatch(
    do.call(c, unname(layers)),
    error = function(e) {
      warning(sprintf("Cannot stack '%s': %s", sp_name, conditionMessage(e)))
      NULL
    }
  )
  if (is.null(stk)) return(NULL)
  names(stk) <- names(layers)

  # extract values
  vals <- values(stk)

  # no future data: set present to NA too (temporary, until land masks match)
  # (reference map aligned to this species' grid, extents can differ)
  fut_mask <- if (has_ssp2) {
    vals[, "present_ssp2"]
  } else {
    values(crop(extend(rast(ref_future), r_now), r_now))[, 1]
  }
  if (length(fut_mask) != nrow(vals)) stop(sprintf("Future mask does not match grid for '%s'", sp_name))
  vals[is.na(fut_mask), "present_now"] <- NA

  # missing future map: all 5 models assumed to agree with present
  ssp2 <- if (has_ssp2) vals[, "present_ssp2"] else vals[, "present_now"] * 5L
  ssp3 <- if (has_ssp3) vals[, "present_ssp3"] else vals[, "present_now"] * 5L

  # keep pixels present in any scenario OR within hull
  keep <- (!is.na(vals[, "present_now"]) & vals[, "present_now"] == 1L) |
    (!is.na(vals[, "hull_val"]))                                      |
    (!is.na(ssp2) & ssp2 >= 1L)                                       |
    (!is.na(ssp3) & ssp3 >= 1L)

  if (!any(keep)) return(NULL)

  # compute coords from cropped r_now (grid changed after crop)
  coords_sp <- xyFromCell(r_now, 1:ncell(r_now))

  data.table(
    species      = sp_name,
    lon          = coords_sp[keep, 1],
    lat          = coords_sp[keep, 2],
    present_now  = as.integer(vals[keep, "present_now"]),
    present_ssp2 = as.integer(ssp2[keep]),
    present_ssp3 = as.integer(ssp3[keep]),
    within_hull  = !is.na(vals[keep, "hull_val"]),
    has_future   = has_future
  )
}

# ---- parallel setup ----------------------------------------
n_cores <- max(1, detectCores() - 6)
cat(sprintf("Using %d cores\n\n", n_cores))

cl <- makeCluster(n_cores)
clusterExport(cl, c("dir_now", "dir_hull", "dir_ssp2", "dir_ssp3", "ref_future"))
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
    dt_chunk[, has_future   := as.logical(has_future)]
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

# ---- merge all chunks into one parquet, sorted by location -
# sorted by lat/lon so the tool's grid cell query only reads a few row groups
cat("Merging chunks (sorted by location)...\n")

chunk_paths <- list.files(chunk_dir, pattern = "\\.parquet$", full.names = TRUE)
if (length(chunk_paths) == 0) stop("No chunk files found — check that chunk writing succeeded above")

# intermediate files outside Dropbox
tmp_root   <- normalizePath(tempdir(), winslash = "/")
band_dir   <- file.path(tmp_root, "parquet_bands")
sorted_dir <- file.path(tmp_root, "parquet_bands_sorted")
unlink(c(band_dir, sorted_dir), recursive = TRUE)
dir.create(sorted_dir)

# connect to in-memory duckdb instance (spills to disk outside Dropbox if needed)
con <- dbConnect(duckdb())
dbExecute(con, sprintf("SET temp_directory = '%s'", file.path(tmp_root, "duckdb_tmp")))

# 1. split all rows into 1-degree latitude bands (one pass over the chunks)
dbExecute(con, sprintf("
  COPY (SELECT *, CAST(floor(lat) AS INTEGER) AS band FROM read_parquet('%s/*.parquet'))
  TO '%s'
  (FORMAT PARQUET, PARTITION_BY (band))
", chunk_dir, band_dir))

# 2. sort each band by lat, lon, species (files numbered from south to north)
bands <- sort(as.integer(sub("^band=", "", list.files(band_dir))))
for (k in seq_along(bands)) {
  cat(sprintf("  sorting band %d/%d (lat %d)\n", k, length(bands), bands[k]))
  dbExecute(con, sprintf("
    COPY (
      SELECT * EXCLUDE (band)
      FROM read_parquet('%s/band=%d/*.parquet', hive_partitioning = true)
      ORDER BY lat, lon, species
    )
    TO '%s/band_%03d.parquet'
    (FORMAT PARQUET)
  ", band_dir, bands[k], sorted_dir, k))
}

# 3. concatenate the sorted bands in order into one file
dbExecute(con, sprintf("
  COPY (SELECT * FROM read_parquet('%s/band_*.parquet'))
  TO '%s'
  (FORMAT PARQUET)
", sorted_dir, out_parquet))

# check: each row group should start at or after the latitude where the previous one ended
rg <- dbGetQuery(con, sprintf("
  SELECT row_group_id, CAST(stats_min_value AS DOUBLE) AS lat_min, CAST(stats_max_value AS DOUBLE) AS lat_max
  FROM parquet_metadata('%s')
  WHERE path_in_schema = 'lat'
  ORDER BY row_group_id
", out_parquet))
cat(sprintf("Row groups: %d, out of latitude order: %d\n", nrow(rg), sum(rg$lat_min[-1] < rg$lat_max[-nrow(rg)])))

dbDisconnect(con, shutdown = TRUE)
unlink(c(band_dir, sorted_dir, file.path(tmp_root, "duckdb_tmp")), recursive = TRUE)

# # read all chunks and write as single parquet file
# ds    <- open_dataset(chunk_dir, format = "parquet")
# dt_all <- as.data.table(ds)
# write_parquet(dt_all, out_parquet, compression = "snappy")
# rm(dt_all); gc()

if (length(skipped) > 0) {
  cat(sprintf("Skipped: %d species (files absent or mismatched)\n", length(skipped)))
  print(skipped)
}

# read parquet into dataframe # gives memory error
# df <- read_parquet(out_parquet)

# get suitable species at a given coordinate using duckdb

# target coordinate
target_lon <- -74
target_lat <- 5

con <- dbConnect(duckdb())

# find species present in the grid cell containing the point (same as the tool)
res <- 1 / 24
cell_lon <- -118 + (floor((target_lon + 118) / res) + 0.5) * res
cell_lat <- 34 - (floor((34 - target_lat) / res) + 0.5) * res
t_query <- system.time(species_here <- dbGetQuery(con, sprintf("
  SELECT DISTINCT species
  FROM read_parquet('%s')
  WHERE present_now = 1
    AND lon BETWEEN %.8f AND %.8f
    AND lat BETWEEN %.8f AND %.8f
", out_parquet, cell_lon - res / 4, cell_lon + res / 4, cell_lat - res / 4, cell_lat + res / 4)))
cat(sprintf("Test query: %d species in %.1f s\n", nrow(species_here), t_query[["elapsed"]]))

dbDisconnect(con)

# clean vector of species names
species_vec <- species_here$species





