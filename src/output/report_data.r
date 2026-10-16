# =============================================================================
# Generate report data as JSON for a frontend (WordPress) to render.
# Replaces the previous report_html.r (R2HTML-based) approach.
# Same pattern as conservation-lambda-r/src/output/report_data.r.
# =============================================================================

generate_report_data <- function(inputs,
                                 country,
                                 region,
                                 biome_name,
                                 species_filt,
                                 trans_df,
                                 output_folder) {

  log_step("n11 [report_data]", "Building report data JSON...")

  # Clean species table — add row index for DataTables
  species_df <- species_filt$nutr_table
  rownames(species_df) <- NULL
  if (nrow(species_df) > 0) {
    species_df$id <- seq_len(nrow(species_df))
  }

  # Translation labels for the selected language (may be NULL if trans_df empty)
  labels <- if (!is.null(trans_df) && nrow(trans_df) > 0) as.list(trans_df) else list()

  # Species without future maps: show text instead of a percentage
  if (nrow(species_df) > 0) {
    no_fut <- is.na(species_df$future_suitability)
    species_df$future_suitability <- as.character(species_df$future_suitability)
    species_df$future_suitability[no_fut] <- labels$no_future_projections
  }

  # Assemble the payload: echoes the inputs, adds derived context, ships the results.
  report_data <- list(
    coords = list(lon = inputs$lon, lat = inputs$lat),
    country = country,
    region = region,
    biome = biome_name,
    filters = list(
      edible_parts_ID = inputs$edible_parts_ID,
      food_groups_ID = inputs$food_groups_ID,
      growth_forms_ID = inputs$growth_forms_ID,
      species_type_ID = inputs$species_type_ID,
      soil_con_ID = inputs$soil_con_ID,
      within_range = inputs$within_range,
      incl_tentative = inputs$incl_tentative,
      SSP = inputs$SSP,
      language_output = inputs$language_output
    ),
    n_species = nrow(species_df),
    species = if (nrow(species_df) > 0) species_df else NULL,
    labels = labels
  )

  # Canonical JSON (consumed by WP PHP / any REST client)
  json_file <- file.path(output_folder, "data.json")
  writeLines(
    jsonlite::toJSON(report_data, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
    json_file
  )

  # data.js — same payload exposed on `window.d4nReport` for direct <script src> loading.
  # Useful if the report wrapper HTML wants the data without a fetch().
  js_file <- file.path(output_folder, "data.js")
  writeLines(
    paste0(
      "window.d4nReport = ",
      jsonlite::toJSON(report_data, auto_unbox = TRUE, null = "null", na = "null"),
      ";"
    ),
    js_file
  )

  # Dev-only: when running locally (USE_LOCAL_FILES=TRUE), drop a copy of
  # tools/local_viewer.html next to data.js so the run can be opened in a
  # browser without extra steps. Deliberately skipped on Lambda — the
  # production report is served by WordPress from its own template in a
  # separate repo; the viewer here must never touch S3 / prod.
  if (isTRUE(use_local)) {
    viewer_path <- file.path(R_HOME, "tools", "local_viewer.html")
    if (file.exists(viewer_path)) {
      file.copy(viewer_path, file.path(output_folder, "local_viewer.html"), overwrite = TRUE)
    }
  }

  invisible(report_data)
}
