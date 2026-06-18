# function to resolve config.R path
resolve_config_path <- function() {
  candidates <- c("config.r")
  
  lambda_root <- Sys.getenv("LAMBDA_TASK_ROOT", unset = "")
  if (nzchar(lambda_root)) {
    candidates <- c(candidates, file.path(lambda_root, "config.r"))
  }
  
  frame_files <- vapply(sys.frames(), function(fr) {
    if (!is.null(fr$ofile)) fr$ofile else ""
  }, character(1))
  frame_files <- frame_files[nzchar(frame_files)]
  if (length(frame_files) > 0) {
    source_dir <- dirname(normalizePath(frame_files[length(frame_files)], winslash = "/", mustWork = FALSE))
    candidates <- c(candidates, file.path(source_dir, "config.r"))
  }
  
  existing <- unique(candidates[file.exists(candidates)])
  if (length(existing) == 0) {
    stop("No se encontro config.r. Verifique que este archivo exista en el proyecto.")
  }
  existing[1]
}
source(resolve_config_path())
rm(resolve_config_path)

# Publish a job status marker to S3 so asynchronous callers (WordPress) can poll
# progress without holding the HTTP request open. The marker lives inside the
# report folder (diversity/<job_id>/status.json) so the existing report_* S3
# lifecycle rule cleans it up too. Non-fatal, and skipped in local mode.
write_job_status <- function(job_id, status) {
  if (isTRUE(use_local) || is.null(s3)) {
    return(invisible(NULL))
  }
  tryCatch({
    key <- paste(OUTPUT_FOLDER, job_id, "status.json", sep = "/")
    body <- charToRaw(jsonlite::toJSON(status, auto_unbox = TRUE, pretty = TRUE))
    s3$put_object(
      Bucket = BUCKET_NAME,
      Key = key,
      Body = body,
      ContentType = "application/json"
    )
  }, error = function(e) {
    cat(paste0("[mainNutrition][WARN] could not write job status for ", job_id,
      ": ", conditionMessage(e), "\n"))
  })
}

# main function, which calls process_nutrition function
mainNutrition <- function(lon,
                          lat,
                          edible_parts_ID,
                          food_groups_ID,
                          growth_forms_ID,
                          species_type_ID,
                          soil_con_ID,
                          within_range,
                          incl_tentative,
                          SSP,
                          language_output,
                          job_id = NULL) {

  date_download <<- format(Sys.time(), "report_%Y-%m-%d_%H-%M-%S")
  REPORT_FOLDER <<- file.path(tempdir(), date_download)
  dir.create(REPORT_FOLDER, recursive = TRUE, showWarnings = FALSE)

  # Async mode: when the caller provides a job_id it dictates the output folder
  # name, so the result location is predictable without reading the invocation
  # response (InvocationType=Event). We also publish a status.json marker the
  # caller polls. Without job_id the function behaves exactly as before for
  # synchronous (RequestResponse) callers.
  async_mode <- !is.null(job_id) && nzchar(job_id)
  if (async_mode) {
    # Defensive: keep job_id to a safe S3-key charset (PHP already validates).
    job_id <- gsub("[^A-Za-z0-9_-]", "", job_id)
    date_download <<- job_id
    REPORT_FOLDER <<- file.path(tempdir(), job_id)
    dir.create(REPORT_FOLDER, recursive = TRUE, showWarnings = FALSE)
    write_job_status(job_id, list(
      state = "running",
      started_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    ))
  }

  setwd(R_HOME)
  source(file.path(R_HOME, "src", "libs.r"))
  source(file.path(R_HOME, "src", "io", "utils.r"))
  source(file.path(R_HOME, "src", "io", "analytics.r"))
  if (!isTRUE(use_local)) init_cache()
  source("nutrition.r")

  for (g in c("d4r_last_country", "d4r_last_region", "d4r_last_parsed")) {
    if (exists(g, envir = .GlobalEnv)) rm(list = g, envir = .GlobalEnv)
  }

  start_time <- Sys.time()
  request_id <- Sys.getenv("D4R_REQUEST_ID", unset = "")

  result <- tryCatch({process_nutrition(
    lon = lon,
    lat = lat,
    edible_parts_ID = edible_parts_ID,
    food_groups_ID = food_groups_ID,
    growth_forms_ID = growth_forms_ID,
    species_type_ID = species_type_ID,
    soil_con_ID = soil_con_ID,
    within_range = within_range,
    incl_tentative = incl_tentative,
    SSP = SSP,
    language_output = language_output
    )
    
    files_to_copy <- list.files(
      REPORT_FOLDER, recursive = TRUE, full.names = TRUE
    )
    for (file in files_to_copy) {
      upload_to_s3(file, REPORT_FOLDER, OUTPUT_FOLDER, BUCKET_NAME)
    }
    report_path <- if (isTRUE(use_local)) {
      file.path(local_base_path, OUTPUT_FOLDER, date_download)
    } else {
      paste(OUTPUT_FOLDER, date_download, sep = "/")
    }
    cat(paste0("\n[mainNutrition] Report path: ", report_path, "\n"))

    # Publish "done" only AFTER every artifact is in S3, so a poller that sees
    # done can safely download the full folder (incl. data.json).
    if (async_mode) {
      write_job_status(job_id, list(
        state = "done",
        report_path = report_path,
        finished_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
      ))
    }

    g <- function(n) if (exists(n, envir = .GlobalEnv)) get(n, envir = .GlobalEnv) else NULL
    log_execution(build_execution_record(
      start_time = start_time, end_time = Sys.time(),
      request_id = request_id,
      country = g("d4r_last_country"), region = g("d4r_last_region"),
      lon = suppressWarnings(as.numeric(lon)),
      lat = suppressWarnings(as.numeric(lat)),
      parsed = list(language_output = language_output, SSP = SSP,
                    within_range = within_range, incl_tentative = incl_tentative,
                    edible_parts_ID = edible_parts_ID,
                    food_groups_ID = food_groups_ID,
                    growth_forms_ID = growth_forms_ID,
                    species_type_ID = species_type_ID,
                    soil_con_ID = soil_con_ID),
      success = TRUE
    ))

    list(success = TRUE, report_path = report_path)
  }, error = function(e) {
    # Retornar error estructurado para que PHP/FE muestren el mensaje amigable
    msg <- conditionMessage(e)
    cat(paste0("\n[mainNutrition][ERROR] ", msg, "\n"))
    if (!is.null(e$call)) {
      cat(paste0("[mainNutrition][ERROR_CALL] ", deparse(e$call), "\n"))
    }

    if (isTRUE(async_mode)) {
      write_job_status(job_id, list(
        state = "error",
        message = msg,
        finished_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
      ))
    }

    g <- function(n) if (exists(n, envir = .GlobalEnv)) get(n, envir = .GlobalEnv) else NULL
    log_execution(build_execution_record(
      start_time = start_time, end_time = Sys.time(),
      request_id = request_id,
      country = g("d4r_last_country"), region = g("d4r_last_region"),
      lon = suppressWarnings(as.numeric(lon)),
      lat = suppressWarnings(as.numeric(lat)),
      parsed = list(language_output = language_output, SSP = SSP),
      success = FALSE, error_msg = msg
    ))

    list(success = FALSE, message = msg)
  })

  result
}

# test the connection
test_connection <- function() {
  library(httr)
  
  response <- tryCatch({
    GET("https://www.google.com")
  }, error = function(e) {
    cat("Error in the HTTP request: ", e$message)
  })
  
  if (inherits(response, "response")) {
    cat("Connection to Google successful.\n")
  } else {
    cat("Could not establish connection to Google.\n")
  }
}