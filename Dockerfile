ARG BASE_IMAGE=315134288138.dkr.ecr.us-east-1.amazonaws.com/r-lambda-d4n-base:latest
FROM ${BASE_IMAGE}

# Bake the D4N working set into the image (read-only) so reports don't download
# the 1.5 GB D4N_maps.parquet from S3 on every cold start. Only the files the
# runtime actually reads are baked — NOT Maps/ (29 GiB of rasters that
# load_maps.r no longer uses). Data is NOT versioned in git: S3 is the source of
# truth, run scripts/sync_data.sh to populate baked_data/ before building.
# Kept as an early layer so code-only changes don't invalidate it.
#
# Deliberately no GDAL_PAM_ENABLED here: it looked like a safe guard for the
# read-only /opt but cost C4R 40% of its runtime (GDAL recomputes raster
# statistics on every open without PAM). If a site ever needs it, measure it.
COPY baked_data/ /opt/d4n_data/
ENV BAKED_DATA_DIR=/opt/d4n_data

COPY runtime.r functions.r nutrition.r config.r /var/task/
COPY src/ /var/task/src/
RUN chmod 755 -R /var/task/

RUN printf '#!/bin/sh\ncd $LAMBDA_TASK_ROOT\nRscript runtime.r' > /var/runtime/bootstrap \
    && chmod +x /var/runtime/bootstrap

CMD ["functions.mainNutrition"]
