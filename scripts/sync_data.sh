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
# Skipping step 4 after step 2 is safe: init_cache() detects the version
# mismatch, disables the baked directory and falls back to S3.
set -euo pipefail

BUCKET="${BUCKET:-d4n-data}"
ROOT="${ROOT:-D4N_data}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_DIR/baked_data/$ROOT"

# Directory-level prefixes only, never individual files: the baked branch of
# download_from_s3() returns a .shp path directly without fetching its
# companions, so a partially synced shapefile would fail silently at runtime.
PREFIXES=(
  "Tables"
  "Shapefile biomes"
  "world_shp"
)
FILES=(
  "D4N_maps.parquet"
  "cache_version.txt"
)

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
