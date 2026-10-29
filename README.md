# Diversity for Nutrition

R backend for the Diversity for Nutrition tool. Given a location (longitude, latitude) and user-defined filters, the tool identifies edible plant species that can be grown at that location and returns them with their edible part, food group, use, future suitability and references. It runs as a custom R runtime on AWS Lambda; the report is rendered by the WordPress front-end.

## How it works

1. **Parse inputs** — convert and validate all parameters arriving as strings
2. **Load data** — read the species nutrition data, soil extremes, lookup tables and translations (from S3 or local)
3. **Biome, country and region** — look up the biome and country at the coordinates (shapefiles)
4. **Suitable species** — query `D4N_maps.parquet` (DuckDB) at the nearest grid cell: species present now, optionally within their known range (convex hull), plus the number of models predicting future presence for the selected SSP
5. **Filter species** — by tentative edible parts/food groups, edible parts, food groups, growth forms, wild/cultivated and soil conditions
6. **References** — number the unique edible part and use references of the species in the table
7. **Output** — write `data.json` / `data.js` (species table, references table, translation labels) and upload to S3

Future suitability is shown as the % of the 5 models predicting future presence, or "No future projections made" for species without future maps.

## Entry point

```r
source("functions.r")

mainNutrition(
  lon             = -49.91,
  lat             = -26.34,
  edible_parts_ID = "5,8",
  food_groups_ID  = "3,15",
  growth_forms_ID = "1",
  species_type_ID = "1",
  soil_con_ID     = "2",
  within_range    = "yes",
  incl_tentative  = "yes",
  SSP             = "SSP2",
  language_output = "EN"
)
```

All parameters are passed as strings (as received from the web app). ID lists are comma-separated, `"NULL"` means no filter. See `test_runner.R` for a working example.

## Project structure

```
runtime.r                # Lambda custom runtime (polls events, calls mainNutrition)
functions.r              # Entry point — mainNutrition(): report folder, error handling, S3 upload, analytics
nutrition.r              # Orchestrator — process_nutrition()
config.r                 # Runtime config (local vs Lambda/S3)
src/
  libs.r                 # Packages
  io/
    utils.r              # S3/local file I/O, country and region lookup
    helpers.r            # Logging, CSV reading
    analytics.r          # Per-execution analytics log on S3 (production only)
  input/
    parse_inputs.r       # Input parsing and type conversion
    get_biome.r          # Biome at the coordinates
  data/
    load_data.r          # Load nutrition data, soil extremes, lookup tables, translations
    load_maps.r          # Legacy raster loading (no longer used)
  analysis/
    species_analysis.r   # Suitable species (parquet), filters, references
  output/
    report_data.r        # Build data.json / data.js
tools/
  local_viewer.html      # Dev-only viewer for local runs
  build_species_index.py # Species index + presence tiles for the front-end's species-count preview
  check_presence_tiles.py # Proves the tiles answer like the Lambda's cell query
scripts/
  backfill_executions.R  # One-off backfill of analytics logs
  sync_data.sh           # Sync the working set from S3 into baked_data/ for the image
  slim_parquet.R         # Derive the slim D4N_maps.parquet baked into the image
  check_slim_parquet.R   # Prove the slim parquet answers like the full one
```

## Data

Expected data folder structure (S3 bucket: `d4n-data`, default prefix: `D4N_data`):

```
D4N_maps.parquet                       # One row per species x grid cell (see below)
cache_version.txt                      # Change after uploading new data, so Lambda refreshes its cache
Tables/
  D4N_species_nutrition_data.csv       # One row per species x edible part x food group
  D4N_soil_extremes.csv                # Species x soil variable, with soil extreme category
  D4N_plant_parts.csv                  # Filter IDs -> labels
  D4N_food_groups.csv
  D4N_growth_forms.csv
  D4N_species_types.csv
  D4N_translation_backend.csv          # Report labels per language (EN, ES)
Shapefile biomes/Ecoregions_LATAM.shp
world_shp/WB_countries_Admin0_10m.shp
```

`D4N_maps.parquet` columns: `species`, `lon`, `lat`, `present_now` (0/1), `present_ssp2` / `present_ssp3` (number of models, 0–5), `within_hull`, `has_future` (FALSE if future values were filled from present).

## Updating the data

These scripts in the project root prepare the data and are not part of the tool itself:

- `prepare parquet table instead of maps.R` — builds the parquet from the species maps (`Maps/Presence-absence`, `Maps/Future/{SSP}` and the hull-masked versions). Writes `D4N_merged.parquet`; check it, then rename it to `D4N_maps.parquet`. Needs a few GB of RAM and disk space; lower `n_cores` if memory is tight.
- `process soil extremes data.R` — flags soil outliers from the continental soil outliers table and writes `D4N_soil_extremes.csv`.
- `clean up nutrition data.R` — fixes encoding and maps known label variants in `D4N_species_nutrition_data.csv` to the lookup tables. Rerun after every export from Excel; it prints the values that still need a decision.
- `food groups based on use descriptions.R` — assigns food groups from use descriptions (pre-processing of the species list).

After updating any data file, upload it to S3 and change `cache_version.txt`.

The Lambda image does not bake `D4N_maps.parquet` as delivered. `scripts/sync_data.sh` derives a slim copy with `scripts/slim_parquet.R`: every `present_now == 1` row, plus one marker row for each grid cell that has none (so the cell still counts as having data for the nearest-cell fallback), in the original order, ZSTD-compressed in larger row groups. The runtime query and its answer are unchanged; `scripts/check_slim_parquet.R` proves it cell by cell. For the 2026-10 data that is 0.93 GB instead of 5.8 GB, and a cell query reads much less. The delivered file in S3 is never replaced, and a stale image falls back to it.

## Front-end preview data

The WordPress form counts, before a report is run, how many species the report would keep. `tools/build_species_index.py` builds what it needs from the same dataset the Lambda reads:

- `D4N_species_index.json` — one row per species × edible part × food group, with the filter IDs, the tentative flag and the species' soil extreme categories (`o`; the soil filter is per species, not per site).
- presence tiles (with `--parquet` and `--tiles-out`) — for every 2.5' grid cell, the index species with `present_now == 1`, and those also `within_hull`, as two bitsets per cell, packed in 0.5° tiles. The binary format is documented at the top of the script.

```bash
python3 tools/build_species_index.py --src baked_data/D4N_data_2026-10/Tables \
  --index-file /tmp/d4n/D4N_species_index.json \
  --parquet baked_data/D4N_data_2026-10/D4N_maps.parquet --tiles-out /tmp/d4n/presence
python3 tools/check_presence_tiles.py --src baked_data/D4N_data_2026-10/Tables \
  --parquet baked_data/D4N_data_2026-10/D4N_maps.parquet \
  --index /tmp/d4n/D4N_species_index.json --tiles /tmp/d4n/presence/<version>
aws s3 sync /tmp/d4n/presence/<version> s3://d4n-data/tool-maps/d4n/presence/<version>/
```

The tile folder is named after the index `version` (`:` replaced by `-`), so an index and its tiles always ship together; the theme copies the index into the plugin and points its config at that folder. Rebuild both whenever the tables or the parquet change. Needs Python with `duckdb` and `numpy`.

## Local development

Outside Lambda, `config.r` sets `USE_LOCAL_FILES=TRUE` and `LOCAL_DATA_PATH` to the local data folder by default. Set them yourself before sourcing to override:

```r
Sys.setenv(USE_LOCAL_FILES = "TRUE")
Sys.setenv(LOCAL_DATA_PATH = "C:/path/to/diversity-for-nutrition-data")
```

Each local run writes three files into `<LOCAL_DATA_PATH>/diversity/report_<timestamp>/`:

- `data.json` — structured output (coords, country, region, biome, filters, species table, references table, translation labels).
- `data.js` — same payload as a `window.d4nReport` assignment, consumed by the local viewer.
- `local_viewer.html` — a **dev-only** HTML viewer that renders `data.js` as tables + mini-map. Open this file in your browser right after the run to inspect results visually.

The viewer is intentionally independent from the production report (which lives in the WordPress theme repo). It only exists to validate local runs and is never uploaded to S3 or shown to end users.

## Dependencies

- `duckdb` — parquet queries
- `terra` — biome and country lookup (shapefiles)
- `jsonlite` — JSON output
- `paws` — AWS S3 (only needed when `USE_LOCAL_FILES=FALSE`)
- `httr` — Lambda runtime API (`runtime.r`)
- Data preparation only: `arrow`, `data.table`, `readxl`
