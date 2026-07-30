# Shared runtime configuration for Lambda and local execution.

# Local development defaults — only applied outside Lambda, and only when the
# env var is not already set. Override by setting the env var before sourcing.
if (!nzchar(Sys.getenv("LAMBDA_TASK_ROOT"))) {
  if (!nzchar(Sys.getenv("USE_LOCAL_FILES")))  Sys.setenv(USE_LOCAL_FILES = "TRUE")
  if (!nzchar(Sys.getenv("LOCAL_DATA_PATH")))  Sys.setenv(LOCAL_DATA_PATH = "C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data")
}

R_HOME <- if (isTRUE(as.logical(Sys.getenv("USE_LOCAL_FILES", unset = "FALSE")))) {
  normalizePath(getwd(), winslash = "/", mustWork = FALSE)
} else {
  "/var/task"
}

BUCKET_NAME <- "d4n-data"
DATA_FOLDER <- Sys.getenv("DATA_FOLDER", unset = "D4N_data")
OUTPUT_FOLDER <- "diversity"
TMP_FOLDER <- tempdir()
CACHE_DIR <- "/tmp/d4n_cache"
CACHE_VERSION_KEY <- file.path(DATA_FOLDER, "cache_version.txt")

# Read-only baked data directory: the working set shipped inside the container
# image (D4N_maps.parquet, Tables/, the shapefiles). When a requested S3 object
# exists here it is served with zero download; otherwise download_from_s3()
# falls back to S3. A missing/empty directory means pure S3 behaviour, so this
# is safe even when nothing is baked. init_cache() clears this value when the
# baked snapshot is older than what S3 advertises. See scripts/sync_data.sh.
BAKED_DIR <- Sys.getenv("BAKED_DATA_DIR", unset = "/opt/d4n_data")

debug_mode <- as.logical(Sys.getenv("debug_mode", unset = "FALSE"))
if (is.na(debug_mode)) {
  debug_mode <- FALSE
}

use_local <- as.logical(Sys.getenv("USE_LOCAL_FILES", unset = "FALSE"))
if (is.na(use_local)) {
  use_local <- FALSE
}

local_base_path <- Sys.getenv("LOCAL_DATA_PATH", unset = "local_data")
if (!nzchar(local_base_path)) {
  local_base_path <- "local_data"
}
local_base_path <- normalizePath(path.expand(local_base_path), winslash = "/", mustWork = FALSE)

s3 <- NULL
if (!use_local) {
  s3 <- paws::s3()
}