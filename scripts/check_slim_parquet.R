# =============================================================================
# Prove that a slim D4N_maps.parquet answers every runtime query exactly like
# the full file it was derived from (see scripts/slim_parquet.R).
#
#   Rscript scripts/check_slim_parquet.R <full.parquet> <slim.parquet>
#
# Checked per one-degree latitude band, over the whole table:
#   cells     the set of grid cells (lon, lat) with at least one row is the
#             same, so the nearest-cell fallback has the same candidates;
#   suitable  per cell, the present_now == 1 rows are the same, with the same
#             species, present_ssp2, present_ssp3, has_future, within_hull,
#             and in the same order (rank in file order);
#   markers   every other slim row is a cell marker: exactly one per cell that
#             has no present_now == 1 row in the full file, none elsewhere,
#             and it is a verbatim row of the full file.
# Exits non-zero on the first difference.
# =============================================================================
suppressMessages(library(duckdb))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) stop("usage: Rscript scripts/check_slim_parquet.R <full.parquet> <slim.parquet>")
full <- normalizePath(args[1], mustWork = TRUE)
slim <- normalizePath(args[2], mustWork = TRUE)

con <- dbConnect(duckdb())
q <- function(sql, ...) dbGetQuery(con, sprintf(sql, ...))

lat_range <- q("
  SELECT min(CAST(stats_min_value AS DOUBLE)) AS lo, max(CAST(stats_max_value AS DOUBLE)) AS hi
  FROM parquet_metadata('%s') WHERE path_in_schema = 'lat'", full)
bands <- seq(floor(lat_range$lo), floor(lat_range$hi))

cols <- "species, present_ssp2, present_ssp3, has_future, within_hull"
tot <- c(cells = 0, suitable = 0, markers = 0, empty_cells = 0)
for (b in bands) {
  where <- sprintf("lat >= %d AND lat < %d", b, b + 1L)
  rd <- function(f) sprintf("(SELECT * FROM read_parquet('%s', file_row_number = true) WHERE %s)", f, where)

  # cells: symmetric difference of the two cell sets
  d_cells <- q("
    SELECT count(*) AS n FROM (
      (SELECT DISTINCT lon, lat FROM %1$s EXCEPT SELECT DISTINCT lon, lat FROM %2$s)
      UNION ALL
      (SELECT DISTINCT lon, lat FROM %2$s EXCEPT SELECT DISTINCT lon, lat FROM %1$s))",
    rd(full), rd(slim))$n

  # suitable rows with their rank inside the cell (set ops compare NULLs as equal)
  suit <- function(f) sprintf("
    SELECT lon, lat, %s, row_number() OVER (PARTITION BY lon, lat ORDER BY file_row_number) AS k
    FROM %s WHERE present_now = 1", cols, rd(f))
  d_suit <- q("
    SELECT count(*) AS n FROM (
      (%1$s EXCEPT ALL %2$s) UNION ALL (%2$s EXCEPT ALL %1$s))", suit(full), suit(slim))$n

  # markers: one per cell without suitable rows, and a verbatim full row
  m <- q("
    WITH fc AS (
      SELECT lon, lat, bool_or(present_now = 1) IS TRUE AS has_suitable
      FROM %1$s GROUP BY lon, lat),
    sm AS (
      SELECT lon, lat, count(*) AS n FROM %2$s
      WHERE present_now IS DISTINCT FROM 1 GROUP BY lon, lat)
    SELECT
      (SELECT count(*) FROM fc) AS cells,
      (SELECT count(*) FROM fc WHERE NOT has_suitable) AS empty_cells,
      (SELECT count(*) FROM sm) AS marker_cells,
      (SELECT count(*) FROM sm WHERE n <> 1) AS multi_marker_cells,
      (SELECT count(*) FROM sm JOIN fc USING (lon, lat) WHERE fc.has_suitable) AS markers_in_suitable_cells,
      (SELECT count(*) FROM %2$s WHERE present_now = 1) AS suitable,
      (SELECT count(*) FROM (
         SELECT species, lon, lat, present_now, present_ssp2, present_ssp3, within_hull, has_future
         FROM %2$s WHERE present_now IS DISTINCT FROM 1
         EXCEPT
         SELECT species, lon, lat, present_now, present_ssp2, present_ssp3, within_hull, has_future
         FROM %1$s)) AS foreign_markers",
    rd(full), rd(slim))

  bad <- d_cells != 0 || d_suit != 0 || m$marker_cells != m$empty_cells ||
    m$multi_marker_cells != 0 || m$markers_in_suitable_cells != 0 || m$foreign_markers != 0
  if (bad) {
    print(cbind(band = b, cell_diff = d_cells, suitable_diff = d_suit, m))
    stop(sprintf("slim file differs from the full file in latitude band %d", b))
  }
  tot <- tot + c(m$cells, m$suitable, m$marker_cells, m$empty_cells)
}

# Every slim row was checked by some band, and no full row escaped the bands
# (a NULL lon/lat could not belong to a cell).
n_slim <- q("SELECT count(*) AS n FROM read_parquet('%s')", slim)$n
if (n_slim != tot[["suitable"]] + tot[["markers"]]) stop("slim rows outside the checked bands")
n_null <- q("SELECT count(*) AS n FROM read_parquet('%s') WHERE lon IS NULL OR lat IS NULL", full)$n
if (n_null != 0) stop(n_null, " full rows have no lon/lat")

cat(sprintf("OK: %d bands, %s cells (%s without suitable species), %s suitable rows, %s markers: identical\n",
  length(bands), format(tot[["cells"]], big.mark = ","), format(tot[["empty_cells"]], big.mark = ","),
  format(tot[["suitable"]], big.mark = ","), format(tot[["markers"]], big.mark = ",")))
