# =============================================================================
# Derive the slim D4N_maps.parquet that is baked into the Lambda image.
#
#   Rscript scripts/slim_parquet.R <full.parquet> <slim.parquet>
#
# The full file (Tobias's delivery, 2.6 billion rows) keeps one row per
# species per grid cell, whatever its present_now. The runtime only ever uses
# two things from it (src/analysis/species_analysis.r,
# extract_suitable_species_parquet):
#   1. the present_now == 1 rows of the queried cell (species, n_models from
#      present_ssp2/3, has_future, within_hull);
#   2. whether a cell has ANY row at all: a cell with zero rows makes the
#      runtime fall back to the nearest cell that has rows.
# Rows with present_now 0 or NA are otherwise never read, and they are 60% of
# the file. So the slim file keeps:
#   - every present_now == 1 row, unchanged;
#   - for every cell without a present_now == 1 row (all 0 / all NA), exactly
#     one of its original rows (the first in file order) as a marker, so the
#     cell still "has data" and the fallback's candidate cells are the same.
# Rows stay in the original file order (lat, lon, species), so the species of
# a cell come back in the same order as before; only the compression changes.
#
# The result is a derived build artefact, never uploaded over the delivered
# file in S3 (Dropbox/S3 stay byte-for-byte Tobias's delivery). Run it after
# scripts/sync_data.sh, which calls it. Equivalence with the full file is
# checked by scripts/check_slim_parquet.R.
# =============================================================================
suppressMessages(library(duckdb))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) stop("usage: Rscript scripts/slim_parquet.R <full.parquet> <slim.parquet>")
full <- normalizePath(args[1], mustWork = TRUE)
slim <- args[2]

# Writer settings, chosen by measuring (2026-10 data, local duckdb). The
# runtime opens the file afresh for every query, so the footer is parsed every
# time and its size (one entry per row group) dominated the query time: with
# 122,880-row groups (duckdb's default, the full file's) a cell query took
# ~205 ms; 1,966,080-row groups took ~29 ms and also compress better (0.93 GB).
# Larger groups gained nothing more. ZSTD level only changes the write time.
ROW_GROUP_SIZE <- as.integer(Sys.getenv("SLIM_ROW_GROUP_SIZE", "1966080"))
COMPRESSION_LEVEL <- as.integer(Sys.getenv("SLIM_ZSTD_LEVEL", "9"))
PARQUET_VERSION <- Sys.getenv("SLIM_PARQUET_VERSION", "V2")

main <- function() {
  # Intermediate band files (~2 GB) go to a temporary directory, never next to
  # the output: that is baked_data/, and anything left there ends up in the
  # image. Set SLIM_WORK_DIR to keep them and reuse them on the next run, e.g.
  # to try other writer settings quickly; empty it whenever the full file changes.
  work <- Sys.getenv("SLIM_WORK_DIR", "")
  if (!nzchar(work)) {
    work <- tempfile("slim_parquet_")
    on.exit(unlink(work, recursive = TRUE), add = TRUE)
  }
  dir.create(work, showWarnings = FALSE, recursive = TRUE)

  con <- dbConnect(duckdb())
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  invisible(dbExecute(con, sprintf("SET temp_directory = '%s'", file.path(work, "duckdb_tmp"))))
  invisible(dbExecute(con, "SET preserve_insertion_order = true"))

  # One-degree latitude bands, in file order (the file is sorted by lat, so
  # south to north). A cell has a single lat, so it never straddles two bands.
  lat_range <- dbGetQuery(con, sprintf("
    SELECT min(CAST(stats_min_value AS DOUBLE)) AS lo, max(CAST(stats_max_value AS DOUBLE)) AS hi
    FROM parquet_metadata('%s') WHERE path_in_schema = 'lat'", full))
  bands <- seq(floor(lat_range$lo), floor(lat_range$hi))

  band_files <- character(0)
  for (b in bands) {
    out <- file.path(work, sprintf("band_%04d.parquet", match(b, bands)))
    band_files <- c(band_files, out)
    if (file.exists(out)) next
    # file_row_number is the row's position in the full file: it picks the
    # marker deterministically and restores the exact original order.
    invisible(dbExecute(con, sprintf("
      COPY (
        WITH t AS (
          SELECT * FROM read_parquet('%s', file_row_number = true)
          WHERE lat >= %d AND lat < %d
        ),
        cells AS (
          SELECT lon, lat,
                 bool_or(present_now = 1) IS TRUE AS has_suitable,
                 min(file_row_number) AS first_row
          FROM t GROUP BY lon, lat
        )
        SELECT t.species, t.lon, t.lat, t.present_now, t.present_ssp2,
               t.present_ssp3, t.within_hull, t.has_future
        FROM t JOIN cells c ON t.lon = c.lon AND t.lat = c.lat
        WHERE t.present_now = 1
           OR (NOT c.has_suitable AND t.file_row_number = c.first_row)
        ORDER BY t.file_row_number
      ) TO '%s' (FORMAT PARQUET, COMPRESSION SNAPPY)
    ", full, b, b + 1L, paste0(out, ".tmp"))))
    file.rename(paste0(out, ".tmp"), out)
  }

  # Concatenate the bands in order into the final file.
  invisible(dbExecute(con, sprintf("
    COPY (SELECT * FROM read_parquet([%s]))
    TO '%s'
    (FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL %d,
     ROW_GROUP_SIZE %d, PARQUET_VERSION %s)
  ", paste0("'", band_files, "'", collapse = ", "), slim, COMPRESSION_LEVEL, ROW_GROUP_SIZE,
     PARQUET_VERSION)))

  # Every full row must be accounted for, the file must stay in lat order and
  # the column types must be exactly the full file's (the runtime's R types,
  # hence the report, depend on them).
  n <- dbGetQuery(con, sprintf("
    SELECT (SELECT count(*) FROM read_parquet('%s')) AS slim_rows,
           (SELECT count(*) FROM read_parquet('%s') WHERE present_now = 1) AS suitable_rows",
    slim, full))
  schema_of <- function(f) dbGetQuery(con, sprintf("DESCRIBE SELECT * FROM read_parquet('%s')", f))[, 1:2]
  if (!identical(schema_of(full), schema_of(slim))) stop("slim schema differs from the full file")
  rg <- dbGetQuery(con, sprintf("
    SELECT row_group_id, CAST(stats_min_value AS DOUBLE) AS lo, CAST(stats_max_value AS DOUBLE) AS hi
    FROM parquet_metadata('%s') WHERE path_in_schema = 'lat' ORDER BY row_group_id", slim))
  if (any(rg$lo[-1] < rg$hi[-nrow(rg)])) stop("slim row groups are out of latitude order")

  cat(sprintf("slim: %s rows (%s suitable + %s cell markers), %d row groups, %.2f GB\n",
    format(n$slim_rows, big.mark = ","), format(n$suitable_rows, big.mark = ","),
    format(n$slim_rows - n$suitable_rows, big.mark = ","), nrow(rg), file.size(slim) / 1e9))
}

# Wrapped in a function so the on.exit() clean-up runs (it does not at the top
# level of an Rscript).
main()
