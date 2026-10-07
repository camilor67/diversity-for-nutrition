# =============================================================================
# Backfill de ejecuciones historicas (diversity-for-nutrition)
# Recorre s3://d4n-data/diversity/report_* y escribe un JSON liviano por reporte
# en s3://d4n-data/analytics/executions/YYYY/MM/DD/<id>.json.
#
# Aprovecha el data.json del reporte que ya trae country/region/coords/filters.
#
# Idempotente. Uso:
#   Rscript scripts/backfill_executions.R [--dry-run] [--force]
# =============================================================================

suppressPackageStartupMessages({
  library(paws)
  library(jsonlite)
})

args <- commandArgs(trailingOnly = TRUE)
FORCE <- "--force" %in% args
DRY   <- "--dry-run" %in% args

source("config.r")
source("src/io/utils.r")
source("src/io/analytics.r")

if (isTRUE(use_local)) stop("Este script asume S3 real. Desactiva USE_LOCAL_FILES.")

REPORTS_PREFIX <- "diversity/"

list_report_prefixes <- function() {
  prefixes <- character(0)
  token <- NULL
  repeat {
    resp <- s3$list_objects_v2(Bucket = BUCKET_NAME, Prefix = REPORTS_PREFIX,
                               Delimiter = "/", ContinuationToken = token)
    if (!is.null(resp$CommonPrefixes)) {
      for (cp in resp$CommonPrefixes) prefixes <- c(prefixes, cp$Prefix)
    }
    if (isTRUE(resp$IsTruncated)) token <- resp$NextContinuationToken else break
  }
  prefixes
}

parse_report_timestamp <- function(prefix) {
  m <- regmatches(prefix, regexpr("report_\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}", prefix))
  if (length(m) == 0) return(NULL)
  as.POSIXct(sub("report_", "", m), format = "%Y-%m-%d_%H-%M-%S", tz = "UTC")
}

fetch_meta_from_datajson <- function(prefix) {
  key <- paste0(prefix, "data.json")
  tryCatch({
    raw <- s3$get_object(Bucket = BUCKET_NAME, Key = key)$Body
    d <- jsonlite::fromJSON(rawToChar(raw), simplifyVector = TRUE)
    f <- d$filters %||% list()
    list(
      country = if (!is.null(d$country)) as.character(d$country) else NA_character_,
      region  = if (!is.null(d$region))  as.character(d$region)  else NA_character_,
      lon     = if (!is.null(d$coords$lon)) as.numeric(d$coords$lon) else NA_real_,
      lat     = if (!is.null(d$coords$lat)) as.numeric(d$coords$lat) else NA_real_,
      lang    = if (!is.null(f$language_output)) as.character(f$language_output) else NA_character_,
      ssp     = if (!is.null(f$SSP)) as.character(f$SSP) else NA_character_
    )
  }, error = function(e) {
    cat("  WARN: no data.json en ", key, ": ", e$message, "\n", sep = "")
    list(country = NA_character_, region = NA_character_,
         lon = NA_real_, lat = NA_real_, lang = NA_character_, ssp = NA_character_)
  })
}

`%||%` <- function(a, b) if (is.null(a)) b else a

target_exists <- function(key) {
  tryCatch({ s3$head_object(Bucket = BUCKET_NAME, Key = key); TRUE },
           error = function(e) FALSE)
}

main <- function() {
  cat("Listando folders en s3://", BUCKET_NAME, "/", REPORTS_PREFIX, "\n", sep = "")
  prefixes <- list_report_prefixes()
  cat("Encontrados:", length(prefixes), "folders\n")

  written <- 0; skipped <- 0; failed <- 0
  for (prefix in prefixes) {
    ts <- parse_report_timestamp(prefix)
    if (is.null(ts)) { failed <- failed + 1; next }

    id <- paste0("backfill-", format(ts, "%Y%m%d%H%M%S", tz = "UTC"))
    yyyy <- format(ts, "%Y", tz = "UTC"); mm <- format(ts, "%m", tz = "UTC"); dd <- format(ts, "%d", tz = "UTC")
    target_key <- paste(ANALYTICS_PREFIX, yyyy, mm, dd, paste0(id, ".json"), sep = "/")

    if (!FORCE && target_exists(target_key)) { skipped <- skipped + 1; next }

    meta <- fetch_meta_from_datajson(prefix)

    rec <- list(
      ts  = format(ts, "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
      req = id,
      c   = meta$country, r = meta$region,
      ln  = meta$lon, lt = meta$lat,
      ok  = TRUE, ms = NA_integer_,
      lang = meta$lang, ssp = meta$ssp,
      backfilled = TRUE
    )

    if (DRY) {
      cat("[dry] ", target_key, " -> ",
          jsonlite::toJSON(rec, auto_unbox = TRUE, na = "null"), "\n", sep = "")
      next
    }

    tryCatch({
      body <- jsonlite::toJSON(rec, auto_unbox = TRUE, na = "null", null = "null")
      s3$put_object(Bucket = BUCKET_NAME, Key = target_key,
                    Body = charToRaw(as.character(body)),
                    ContentType = "application/json")
      written <- written + 1
      cat(".", sep = "")
      if (written %% 50 == 0) cat(" ", written, "\n", sep = "")
    }, error = function(e) {
      cat("\n  ERROR escribiendo ", target_key, ": ", e$message, "\n", sep = "")
      failed <<- failed + 1
    })
  }
  cat("\nResumen: escritos=", written, " saltados=", skipped, " fallidos=", failed, "\n", sep = "")
}

main()
