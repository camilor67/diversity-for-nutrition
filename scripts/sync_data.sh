#!/bin/bash
#
# Sync the D4N *working set* from S3 into baked_data/ so the Docker build can
# bake it into the image (see Dockerfile: COPY baked_data/ /opt/d4n_data/).
#
# Only what the runtime reads is synced. In particular Maps/ is excluded: it is
# 29 GiB of per-species rasters that species_analysis.r replaced with
# D4N_maps.parquet, and load_maps.r is no longer called (see nutrition.r).
# Syncing the whole prefix would blow past Lambda's 10 GB image limit.
#
# S3 is the source of truth; baked_data/ is a disposable local mirror and is
# git-ignored. The destination keeps the S3 key layout (baked_data/D4N_data/...)
# because download_from_s3() resolves a baked file as
# local_path_from_key(BAKED_DIR, key).
#
# Data update flow:
#   1. Update files in s3://d4n-data/D4N_data/ (source of truth)
#   2. Bump D4N_data/cache_version.txt in S3
#   3. ./scripts/sync_data.sh
#   4. ./build.sh function && ./build.sh deploy      # -> $LATEST (staging)
#
# A new dataset can instead live under its own prefix, so the version :prod
# runs keeps reading the old one untouched (2026-10: D4N_data_2026-10):
#   ROOT=D4N_data_2026-10 ./scripts/sync_data.sh
# and set the function's env DATA_FOLDER to the same prefix. ROOT must match
# DATA_FOLDER: the runtime looks baked files up by S3 key.
#
# Skipping step 4 after step 2 is safe: init_cache() detects the version
# mismatch, disables the baked directory and falls back to S3.
#
# D4N_maps.parquet is NOT baked as delivered: scripts/slim_parquet.R derives a
# slim copy (only the present_now == 1 rows plus one marker row per cell
# without them, ~0.9 GB instead of 5.8 GB) and scripts/check_slim_parquet.R
# proves it answers every runtime query like the full file. The full file is
# kept outside baked_data/ (FULL_DIR) so it never reaches the image, and S3
# keeps the delivered file untouched. If the baked data goes stale the runtime
# reads the full file from S3, which gives the same reports.
# Needs R with the duckdb package; SKIP_SLIM_CHECK=1 skips the proof (~15 min on 14 cores).
set -euo pipefail

BUCKET="${BUCKET:-d4n-data}"
ROOT="${ROOT:-D4N_data}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_DIR/baked_data/$ROOT"
FULL_DIR="${FULL_DIR:-$REPO_DIR/data_full/$ROOT}"

# Directory-level prefixes only, never individual files: the baked branch of
# download_from_s3() returns a .shp path directly without fetching its
# companions, so a partially synced shapefile would fail silently at runtime.
PREFIXES=(
  "Tables"
  "Shapefile biomes"
  "world_shp"
)
FILES=(
  "cache_version.txt"
)

# Only one dataset may be baked: the Dockerfile copies all of baked_data/, and
# a second prefix left over from an earlier sync would bloat the image towards
# Lambda's 10 GB limit while never being read.
for other in "$REPO_DIR"/baked_data/*/; do
  [ -d "$other" ] || continue
  if [ "$(basename "$other")" != "$ROOT" ]; then
    echo "ERROR: baked_data/ also holds $(basename "$other"); remove it before baking $ROOT." >&2
    exit 1
  fi
done

mkdir -p "$DEST"

for p in "${PREFIXES[@]}"; do
  echo ">>> Syncing $ROOT/$p"
  aws s3 sync "s3://$BUCKET/$ROOT/$p" "$DEST/$p" --delete --exact-timestamps \
    --exclude '*.DS_Store'
done

for f in "${FILES[@]}"; do
  echo ">>> Copying $ROOT/$f"
  aws s3 cp "s3://$BUCKET/$ROOT/$f" "$DEST/$f" --quiet
done

# The delivered parquet, outside baked_data/ (sync skips it when unchanged).
echo ">>> Syncing the full $ROOT/D4N_maps.parquet into $FULL_DIR"
mkdir -p "$FULL_DIR"
aws s3 sync "s3://$BUCKET/$ROOT" "$FULL_DIR" --exclude '*' --include 'D4N_maps.parquet' \
  --exact-timestamps

echo ">>> Deriving the slim D4N_maps.parquet"
# Without a parquet in baked_data/ the runtime reads the full one from S3 (slow
# but correct); a half-written or unchecked .tmp must never be baked.
rm -f "$DEST/D4N_maps.parquet"
trap 'rm -f "$DEST/D4N_maps.parquet.tmp"' EXIT
Rscript "$REPO_DIR/scripts/slim_parquet.R" "$FULL_DIR/D4N_maps.parquet" "$DEST/D4N_maps.parquet.tmp"
if [ "${SKIP_SLIM_CHECK:-0}" != "1" ]; then
  echo ">>> Checking the slim parquet against the full one"
  Rscript "$REPO_DIR/scripts/check_slim_parquet.R" "$FULL_DIR/D4N_maps.parquet" "$DEST/D4N_maps.parquet.tmp"
fi
mv "$DEST/D4N_maps.parquet.tmp" "$DEST/D4N_maps.parquet"

# Provenance of the derived file (not read by the runtime).
{
  echo "D4N_maps.parquet here is derived by scripts/slim_parquet.R (repo HEAD $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown))"
  echo "from s3://$BUCKET/$ROOT/D4N_maps.parquet:"
  aws s3api head-object --bucket "$BUCKET" --key "$ROOT/D4N_maps.parquet" \
    --query '{size: ContentLength, etag: ETag, last_modified: LastModified}' --output json
} > "$DEST/D4N_maps.parquet.source.txt"

# A shapefile is useless without its companions.
missing=0
while IFS= read -r shp; do
  for ext in shx dbf; do
    companion="${shp%.shp}.$ext"
    if [ ! -f "$companion" ]; then
      echo "ERROR: missing $(basename "$companion") next to $(basename "$shp")" >&2
      missing=1
    fi
  done
done < <(find "$DEST" -type f -name '*.shp')

if [ "$missing" -ne 0 ]; then
  echo "ERROR: incomplete shapefiles in baked_data/. Do not build this image." >&2
  exit 1
fi

# init_cache() refuses to use the baked directory without this marker, since it
# is the only way to tell a current image from a stale one.
if [ ! -f "$DEST/cache_version.txt" ]; then
  echo "ERROR: cache_version.txt was not synced; the staleness guard needs it." >&2
  echo "       Create it in S3: aws s3 cp - s3://$BUCKET/$ROOT/cache_version.txt" >&2
  exit 1
fi

echo ">>> Baked working set:"
du -sh "$DEST"
echo ">>> Files: $(find "$DEST" -type f | wc -l | tr -d ' ')"
