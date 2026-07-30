# =============================================================================
# Loading distribution maps (present) from S3 or local
#
# DEPRECATED — not called by the pipeline. nutrition.r resolves species with
# extract_suitable_species_parquet() against D4N_data/D4N_maps.parquet; the calls
# to load_maps() / extract_suitable_species() there are commented out.
#
# Kept for reference and as an escape hatch, but note what reviving it implies:
# the Maps/ prefix it reads is 29 GiB of per-species rasters, it is NOT baked
# into the image (scripts/sync_data.sh deliberately skips it) and it would not
# fit — Lambda's limit is 10 GB including the base image. Any path built on this
# would download from S3 on every cold start.
# =============================================================================

# load present distribution maps for all species in species_set
load_maps <- function(species_set,
                      DATA_FOLDER,
                      BUCKET_NAME,
                      within_range,
                      SSP,
                      biome,
                      region = NULL) {

  # Root folder for map rasters. When SPLIT_MAPS_BY_REGION=TRUE and region is
  # a known LatAm region (SA/CA), load from "Maps SA" / "Maps CA" for speed.
  # Otherwise (flag off, or region=NA because the click landed outside the
  # LatAm lookup) fall back to the single combined "Maps" folder.
  split_by_region <- isTRUE(as.logical(Sys.getenv("SPLIT_MAPS_BY_REGION", unset = "FALSE")))
  maps_root <- if (split_by_region && !is.null(region) && !is.na(region)) {
    paste0("Maps ", region)
  } else {
    "Maps"
  }

  # load distribution maps present climate
  log_step("n03 [load_maps]", paste0("Loading distribution maps present climate from '", maps_root, "'..."))

  if(within_range == "yes") {
    maps_folder <- file.path(DATA_FOLDER, maps_root, "Presence-absence masked by hull")
  }
  if(within_range == "no") {
    maps_folder <- file.path(DATA_FOLDER, maps_root, "Presence-absence")
  }
  files <- list_files_in_s3(bucket = BUCKET_NAME, prefix = maps_folder)
  files <- files[grepl("\\.tif$", files)]
  distr_stack <- terra::rast(lapply(files, load_raster))

  # change the names to the species names only
  names(distr_stack) <- tools::file_path_sans_ext(basename(sources(distr_stack)))

  # load distribution maps future climate
  log_step("n04 [load_maps]", "Loading distribution maps future climate...")

  if(within_range == "yes") {
    maps_folder <- file.path(DATA_FOLDER, maps_root, "Future masked by hull", SSP)
  }
  if(within_range == "no") {
    maps_folder <- file.path(DATA_FOLDER, maps_root, "Future", SSP)
  }
  files <- list_files_in_s3(bucket = BUCKET_NAME, prefix = maps_folder)
  files <- files[grepl("\\.tif$", files)]
  distr_stack_future <- terra::rast(lapply(files, load_raster))
  
  # change the names to the species names only
  names(distr_stack_future) <- tools::file_path_sans_ext(basename(sources(distr_stack_future)))

  # return of the function
  list(distr_stack = distr_stack, distr_stack_future = distr_stack_future)
  
}

