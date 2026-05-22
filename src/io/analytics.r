# =============================================================================
# Analytics: persistencia liviana por ejecución en S3
# Un JSON pequeño por invocación en:
#   s3://<BUCKET_NAME>/analytics/executions/YYYY/MM/DD/<request_id>.json
# Nunca debe romper la ejecución principal: todo va envuelto en tryCatch.
# =============================================================================

ANALYTICS_PREFIX <- "analytics/executions"

# Solo cuentan invocaciones de la version publicada del alias `prod`.
# AWS_LAMBDA_FUNCTION_VERSION es "$LATEST" sin qualifier (staging / tests con CLI sin
# alias) y un numero ("1", "2", ...) cuando la invocacion pega un alias publicado.
# Fuera de Lambda la variable no existe → excluye runs locales.
.is_production <- function() {
  ver <- Sys.getenv("AWS_LAMBDA_FUNCTION_VERSION", unset = "")
  nzchar(ver) && ver != "$LATEST"
}

.analytics_fallback_id <- function() {
  paste0(
    "local-",
    format(Sys.time(), "%Y%m%d%H%M%S", tz = "UTC"),
    "-",
    paste(sample(c(0:9, letters), 8, replace = TRUE), collapse = "")
  )
}

.analytics_truncate <- function(x, max_len = 300) {
  if (is.null(x) || length(x) == 0 || is.na(x)) return(NULL)
  s <- as.character(x)[1]
  s <- gsub("[\r\n\t]+", " ", s)
  if (nchar(s) > max_len) paste0(substr(s, 1, max_len), "...") else s
}

build_execution_record <- function(start_time, end_time, request_id,
                                   country = NULL, region = NULL,
                                   lon = NULL, lat = NULL,
                                   parsed = NULL,
                                   success = TRUE, error_msg = NULL) {
  rec <- list(
    ts  = format(start_time, "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
    req = if (is.null(request_id) || !nzchar(request_id)) .analytics_fallback_id() else request_id,
    c   = if (!is.null(country)) as.character(country) else NA,
    r   = if (!is.null(region))  as.character(region)  else NA,
    ln  = if (!is.null(lon)) as.numeric(lon) else NA,
    lt  = if (!is.null(lat)) as.numeric(lat) else NA,
    ok  = isTRUE(success),
    ms  = as.integer(round(as.numeric(difftime(end_time, start_time, units = "secs")) * 1000))
  )

  if (!is.null(parsed)) {
    if (!is.null(parsed$language_output)) rec$lang <- parsed$language_output
    if (!is.null(parsed$SSP))             rec$ssp  <- parsed$SSP
    if (!is.null(parsed$within_range))    rec$wr   <- parsed$within_range
    if (!is.null(parsed$incl_tentative))  rec$it   <- parsed$incl_tentative
    obj <- c(parsed$edible_parts_ID, parsed$food_groups_ID,
             parsed$growth_forms_ID, parsed$species_type_ID,
             parsed$soil_con_ID)
    obj <- obj[!is.null(obj) & obj != "NULL" & nzchar(obj)]
    if (length(obj) > 0) rec$obj <- as.character(obj)
  }

  if (!isTRUE(success)) {
    err <- .analytics_truncate(error_msg)
    if (!is.null(err)) rec$err <- err
  }

  rec
}

log_execution <- function(record) {
  if (!.is_production()) {
    cat("  [analytics] skipped (not a published prod version)\n")
    return(invisible(NULL))
  }
  tryCatch({
    if (is.null(record) || !is.list(record)) return(invisible(NULL))

    body <- jsonlite::toJSON(record, auto_unbox = TRUE, null = "null", na = "null")

    ts_chr <- record$ts
    date_part <- substr(ts_chr, 1, 10)
    yyyy <- substr(date_part, 1, 4)
    mm   <- substr(date_part, 6, 7)
    dd   <- substr(date_part, 9, 10)
    key <- paste(ANALYTICS_PREFIX, yyyy, mm, dd,
                 paste0(record$req, ".json"), sep = "/")

    if (isTRUE(use_local)) {
      dest <- local_path_from_key(local_base_path, key)
      dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
      writeLines(as.character(body), dest, useBytes = TRUE)
      cat(paste0("  [analytics] wrote ", dest, "\n"))
      return(invisible(dest))
    }

    s3$put_object(
      Bucket      = BUCKET_NAME,
      Key         = key,
      Body        = charToRaw(as.character(body)),
      ContentType = "application/json"
    )
    cat(paste0("  [analytics] s3://", BUCKET_NAME, "/", key, "\n"))
    invisible(key)
  }, error = function(e) {
    cat(paste0("  [analytics] WARN: could not persist execution log: ", e$message, "\n"))
    invisible(NULL)
  })
}
