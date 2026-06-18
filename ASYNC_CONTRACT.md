# Async job contract (render-report)

The WordPress theme invokes this Lambda **asynchronously** (`InvocationType=Event`)
and polls S3 for progress instead of holding the HTTP request open. This document
defines the contract, replicated from the D4R reference Lambda (`d4r-lambda-r`).

## Invocation

WordPress generates a `job_id` and passes it in the payload alongside the existing
arguments:

```
job_id = "report_<YYYY-MM-DD_HH-MM-SS>_<8 hex>"   # always starts with "report_"
```

- `mainNutrition()` accepts `job_id` as an **optional trailing parameter**
  (`job_id = NULL`).
- When `job_id` is present (async mode): it **dictates the output folder name**, so
  the result location is `diversity/<job_id>/` (OUTPUT_FOLDER from `config.r`) —
  predictable by the caller without reading the invocation response.
- When `job_id` is absent: behaviour is **unchanged** (synchronous
  `RequestResponse` callers keep working). Backward compatible during rollout.

## Status marker

The Lambda publishes a small JSON marker (via `write_job_status()` in
`functions.r`, using the global `s3` paws client and `BUCKET_NAME`):

```
s3://d4n-data/diversity/<job_id>/status.json
```

States (written in order):

| When | Body |
|---|---|
| At start (async only) | `{"state":"running","started_at":"<iso8601 UTC>"}` |
| After ALL artifacts uploaded to S3 | `{"state":"done","report_path":"diversity/<job_id>","finished_at":"..."}` |
| On any error (tryCatch) | `{"state":"error","message":"<readable msg>","finished_at":"..."}` |

Key ordering guarantee: `done` is written **only after** every report file
(including `data.json`) is in S3, so a poller that sees `done` can safely download
the whole folder. The marker is skipped in local mode (`USE_LOCAL_FILES=TRUE`).

The marker lives inside the report folder (`diversity/<job_id>/`), so the existing
`report_*` S3 lifecycle rule cleans it up too — no separate rule needed.

## Async invocation config (AWS, set on the function, not in code)

- `MaximumRetryAttempts = 0` — async (Event) invocations otherwise retry on
  failure and would duplicate a multi-minute run.
- `MaximumEventAgeInSeconds` — bound to a sane value (e.g. 900).

## Deploy / safety

- Build with `./build.sh function` and test against the `$LATEST` version only.
  **Do not move the `:prod` alias** until the staging end-to-end test passes.
  Publish a new version and move `:prod` manually as the final production step.
