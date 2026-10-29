#!/usr/bin/env python3
"""
Build the data behind the WordPress tool's species-count preview: a slim
species index (facet counts) and, optionally, presence tiles (which of those
species the report would keep at a clicked site).

One script on purpose: the tiles' bitsets and the index share the species
numbering `s`, and building both in one run guarantees they agree.

Reads (from --src, the dataset's Tables/ folder):
    - D4N_species_nutrition_data.csv   (one row per species × plant_part × food_group × growth_form)
    - D4N_plant_parts.csv              (ID -> text)
    - D4N_food_groups.csv              (ID -> text)
    - D4N_growth_forms.csv             (ID -> text)
    - D4N_species_types.csv            (ID -> text, where text is "wild"/"cultivated")
    - D4N_soil_extremes.csv            (species × soil variable, with category_ID)
and, with --parquet, the dataset's D4N_maps.parquet (the full delivered file
or the slim baked copy: both have the same cells and present_now == 1 rows).

Writes:
    - the index: <--out>/assets/data/D4N_species_index.json, or --index-file
    - with --parquet and --tiles-out: <tiles-out>/<version, ':' -> '-'>/<tx>_<ty>.bin.gz

Index shape (row-level, denormalized — matches R's filter_species semantics):
    {
        "version": "<utc-iso>",
        "n_species": <int>, "n_rows": <int>,
        "rows": [
            {"s": <species_idx>, "p": <part_id|null>, "g": <group_id|null>,
             "f": <[form_id, ...]|null>, "t": <type_id|null>, "tent": <bool>,
             "o": <[soil category_ID, ...]|null>},
            ...
        ]
    }

`f` is a list because growth_form may combine multiple sources with "/"
(e.g. "shrub/tree" = some sources classify it as shrub, others as tree).
The client matches if the user's selection intersects this list.

`o` is the sorted list of the species' soil extreme categories: the distinct
non-NA `category_ID`s of its rows in D4N_soil_extremes.csv, null if it has
none. It is a property of the species, not of the site, so every row of a
species carries the same list. This mirrors filter_species()
(src/analysis/species_analysis.r): the soil filter keeps the species that have
at least one row whose category_ID is among the selected IDs; it does not look
at the point (the `biome` argument it receives is unused). The filter only
applies when the first selected ID is not 1 ("all").

`s` is a 0-based species index assigned by first-seen order in the nutrition
CSV — used for distinct counting on the client and as the bit position in the
tiles; species names are not shipped (smaller payload).

Presence tiles
--------------
The grid is the Lambda's (extract_suitable_species_parquet): 2.5' cells,
res = 1/24 degree, origin lon -118 / lat 34,
    col = floor((lon + 118) * 24),  row = floor((34 - lat) * 24).
The parquet stores cell centres (+0.5 res); they are mapped with
round(x * 24 - 0.5), which equals the floor for a centre and is immune to the
float error in the stored value.

A tile is 12 × 12 cells (0.5 degree): tx = col // 12, ty = row // 12. One file
per tile that has at least one parquet cell, gzip-compressed. The gunzipped
payload is little-endian:

    "D4NP"                 4 bytes ASCII
    format                 uint16 = 1
    nSpecies               uint16 = the index's n_species
    nCells                 uint16
    nCells × cell, ordered by local row, then local col:
        local col          uint8 (col - 12 * tx)
        local row          uint8 (row - 12 * ty)
        ANY                ceil(nSpecies / 8) bytes: present_now = 1
        HULL               ceil(nSpecies / 8) bytes: present_now = 1 AND within_hull
    Bit i of a bitset (byte i // 8, bit i % 8, least significant first) is
    index species s = i.

Every cell with at least one parquet row is written, even when both bitsets
are empty (all its rows are present_now 0/NA, or only species absent from the
nutrition table are present): to the Lambda a cell with rows is a real answer
(zero species), while a cell with no rows makes it fall back to the nearest
cell that has rows. So "cell missing from its tile" = "the Lambda falls back".
Parquet species absent from the nutrition table are dropped (they can never
reach the report: filter_species keeps nutr_dat rows only).

Usage:
    python3 tools/build_species_index.py --src DATA/Tables --index-file OUT.json \\
        [--parquet DATA/D4N_maps.parquet --tiles-out DIR]

Re-run whenever the upstream CSVs or the parquet change, and ship the index
and the tiles of the same run together (the version names the tile folder).
tools/check_presence_tiles.py checks a build against the Lambda's own query.
Needs the duckdb and numpy Python packages for the tiles.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import os
import struct
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DATA_DIR = Path(
    os.path.expanduser(
        "~/Library/CloudStorage/Dropbox/Diversity for Nutrition/"
        "diversity-for-nutrition-data/D4N_data/Tables"
    )
)
DEFAULT_THEME_DIR = Path(
    os.path.expanduser(
        "~/Local Sites/d4n/app/public/wp-content/themes/d4n"
    )
)

# Grid of the Lambda (src/analysis/species_analysis.r).
GRID_LON0 = -118.0
GRID_LAT0 = 34.0
CELLS_PER_DEG = 24
TILE = 12
MAGIC = b"D4NP"
FORMAT = 1


def load_lookup(path: Path, label_col: str) -> dict[str, int]:
    """Load an ID lookup CSV. Returns {label_lower: id_int}. Skips ID 1 ('all')."""
    out: dict[str, int] = {}
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                rid = int(row["ID"])
            except (KeyError, ValueError):
                continue
            if rid == 1:
                continue  # 'all' is a meta-option, not present in source data
            label = (row.get(label_col) or "").strip().lower()
            if label:
                out[label] = rid
    return out


def parse_tentative(val: str | None) -> bool:
    if val is None:
        return False
    v = val.strip().lower()
    return v in {"1", "true", "yes", "y"}


def load_soil_categories(path: Path) -> dict[str, list[int]]:
    """{species: sorted distinct category_IDs} from D4N_soil_extremes.csv.

    R's read.csv reads "NA" (and an empty cell) as NA, and `%in%` never matches
    NA, so those rows never select a species. Species names are matched exactly
    (R compares them with %in%).
    """
    cats: dict[str, set[int]] = {}
    with path.open(newline="", encoding="utf-8") as f:
        for raw in csv.DictReader(f):
            val = (raw.get("category_ID") or "").strip()
            if val in ("", "NA"):
                continue
            cats.setdefault(raw["species"], set()).add(int(val))
    return {sp: sorted(ids) for sp, ids in cats.items()}


def species_numbering(nutr_csv: Path) -> dict[str, int]:
    """{species: s}, s = first-seen order in the nutrition CSV (blank names skipped).

    The same numbering build_index() assigns; the checker uses it to map
    species names to bits.
    """
    species_idx: dict[str, int] = {}
    with nutr_csv.open(newline="", encoding="utf-8", errors="replace") as f:
        for raw in csv.DictReader(f):
            sp = (raw.get("species") or "").strip()
            if sp and sp not in species_idx:
                species_idx[sp] = len(species_idx)
    return species_idx


def build_index(src: Path, version: str) -> tuple[dict, dict[str, int]]:
    plant_parts = load_lookup(src / "D4N_plant_parts.csv", "plant_part")
    food_groups = load_lookup(src / "D4N_food_groups.csv", "food_group")
    growth_forms = load_lookup(src / "D4N_growth_forms.csv", "growth_form")
    species_types = load_lookup(src / "D4N_species_types.csv", "species_type")
    soil = load_soil_categories(src / "D4N_soil_extremes.csv")

    species_idx: dict[str, int] = {}
    rows: list[dict] = []
    skipped = 0

    nutr_csv = src / "D4N_species_nutrition_data.csv"
    with nutr_csv.open(newline="", encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f)
        for raw in reader:
            sp = (raw.get("species") or "").strip()
            if not sp:
                skipped += 1
                continue
            if sp not in species_idx:
                species_idx[sp] = len(species_idx)

            part = plant_parts.get((raw.get("plant_part") or "").strip().lower())
            group = food_groups.get((raw.get("food_group") or "").strip().lower())
            # growth_form may combine sources with "/" (e.g. "shrub/tree"); emit
            # all matching IDs so the client can match on any token.
            raw_form = (raw.get("growth_form") or "").strip().lower()
            form_ids = [growth_forms[t] for t in raw_form.split("/") if t in growth_forms]
            form = form_ids if form_ids else None
            stype = species_types.get((raw.get("wild_or_cultivated") or "").strip().lower())

            tentative = (
                parse_tentative(raw.get("plant_part_tentative"))
                or parse_tentative(raw.get("food_group_tentative"))
            )

            rows.append({
                "s": species_idx[sp],
                "p": part,
                "g": group,
                "f": form,
                "t": stype,
                "tent": tentative,
                "o": soil.get(sp),
            })

    out = {
        "version": version,
        "n_species": len(species_idx),
        "n_rows": len(rows),
        "rows": rows,
    }
    with_soil = sum(1 for sp in species_idx if sp in soil)
    print(f"  species: {out['n_species']:,}   rows: {out['n_rows']:,}   skipped: {skipped:,}"
          f"   with soil categories: {with_soil:,}")
    return out, species_idx


def write_index(out: dict, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        # Compact (no whitespace) — saves ~30% on disk and gzip works well anyway.
        json.dump(out, f, separators=(",", ":"), ensure_ascii=False)
    print(f"Wrote {out_path} ({out_path.stat().st_size / 1024:.1f} KB)")


def tile_dir_name(version: str) -> str:
    return version.replace(":", "-")


def build_tiles(parquet: Path, species_idx: dict[str, int], n_species: int,
                out_dir: Path, threads: int | None = None,
                memory_limit: str = "12GB") -> dict:
    """Write one <tx>_<ty>.bin.gz per tile with data, one tile row (ty) at a time.

    The parquet is sorted by latitude, so a latitude band only reads the row
    groups it overlaps; DuckDB does the join and the cell maths, numpy builds
    the bitsets of one band (~24k cells at most) at a time.
    """
    import duckdb
    import numpy as np

    out_dir.mkdir(parents=True, exist_ok=True)
    nbytes = (n_species + 7) // 8
    nbits = nbytes * 8
    if n_species > 0xFFFF:
        raise ValueError("n_species does not fit the uint16 header")

    con = duckdb.connect()
    con.execute(f"SET memory_limit = '{memory_limit}'")
    if threads:
        con.execute(f"SET threads = {int(threads)}")
    con.execute("CREATE TABLE sp (species VARCHAR, s INTEGER)")
    con.executemany("INSERT INTO sp VALUES (?, ?)", list(species_idx.items()))
    src = f"read_parquet('{parquet}')"

    col_expr = f"CAST(round((lon - ({GRID_LON0})) * {CELLS_PER_DEG} - 0.5) AS INTEGER)"
    row_expr = f"CAST(round(({GRID_LAT0} - lat) * {CELLS_PER_DEG} - 0.5) AS INTEGER)"

    dropped = con.execute(f"""
        SELECT count(*) FROM (SELECT DISTINCT species FROM {src}) p
        WHERE NOT EXISTS (SELECT 1 FROM sp WHERE sp.species = p.species)""").fetchone()[0]
    rmin, rmax, cmin = con.execute(
        f"SELECT min({row_expr}), max({row_expr}), min({col_expr}) FROM {src}").fetchone()
    if rmin < 0 or cmin < 0:
        raise ValueError(f"parquet extends outside the grid origin (row {rmin}, col {cmin})")

    stats = {"tiles": 0, "cells": 0, "raw_bytes": 0, "gz_bytes": 0, "gz_max": 0,
             "dropped_species": dropped, "empty_cells": 0}
    t0 = time.time()
    for ty in range(rmin // TILE, rmax // TILE + 1):
        # Latitude window of the band's cell centres, widened by a quarter cell
        # so float error never loses a row; the exact band is the row test.
        lat_hi = GRID_LAT0 - (ty * TILE + 0.25) / CELLS_PER_DEG
        lat_lo = GRID_LAT0 - ((ty + 1) * TILE - 0.25) / CELLS_PER_DEG
        res = con.execute(f"""
            SELECT {col_expr} AS col, {row_expr} AS row,
                   coalesce(sp.s, -1) AS s,
                   coalesce(p.present_now = 1, false) AS any_p,
                   coalesce(p.present_now = 1 AND p.within_hull, false) AS hull_p
            FROM {src} p LEFT JOIN sp ON sp.species = p.species
            WHERE p.lat BETWEEN {lat_lo!r} AND {lat_hi!r}
              AND {row_expr} // {TILE} = {ty}
        """).fetchnumpy()
        if len(res["col"]) == 0:
            continue
        col = np.asarray(res["col"], dtype=np.int64)
        row = np.asarray(res["row"], dtype=np.int64)
        s = np.asarray(res["s"], dtype=np.int64)
        any_p = np.asarray(res["any_p"], dtype=bool)
        hull_p = np.asarray(res["hull_p"], dtype=bool)
        del res

        # Cells of the band, sorted by (tx, local row, local col) — the file order.
        tx = col // TILE
        key = (tx * TILE + (row - ty * TILE)) * TILE + (col - tx * TILE)
        cells, inv = np.unique(key, return_inverse=True)
        ncell = len(cells)
        any_bits = np.zeros((ncell, nbits), dtype=bool)
        hull_bits = np.zeros((ncell, nbits), dtype=bool)
        known = s >= 0
        m = known & any_p
        any_bits[inv[m], s[m]] = True
        m = known & hull_p
        hull_bits[inv[m], s[m]] = True
        any_packed = np.packbits(any_bits, axis=1, bitorder="little")
        hull_packed = np.packbits(hull_bits, axis=1, bitorder="little")
        del any_bits, hull_bits
        stats["empty_cells"] += int((~any_packed.any(axis=1)).sum())

        cell_tx = cells // (TILE * TILE)
        local = cells % (TILE * TILE)
        lrow = (local // TILE).astype(np.uint8)
        lcol = (local % TILE).astype(np.uint8)
        bounds = np.flatnonzero(np.diff(cell_tx)) + 1
        starts = np.concatenate(([0], bounds))
        ends = np.concatenate((bounds, [ncell]))
        for a, b in zip(starts, ends):
            n = int(b - a)
            parts = [MAGIC, struct.pack("<HHH", FORMAT, n_species, n)]
            for i in range(a, b):
                parts.append(bytes((int(lcol[i]), int(lrow[i]))))
                parts.append(any_packed[i].tobytes())
                parts.append(hull_packed[i].tobytes())
            payload = b"".join(parts)
            gz = gzip.compress(payload, compresslevel=9, mtime=0)
            (out_dir / f"{int(cell_tx[a])}_{ty}.bin.gz").write_bytes(gz)
            stats["tiles"] += 1
            stats["cells"] += n
            stats["raw_bytes"] += len(payload)
            stats["gz_bytes"] += len(gz)
            stats["gz_max"] = max(stats["gz_max"], len(gz))
        print(f"  ty={ty:4d}  cells {ncell:6,}  tiles so far {stats['tiles']:5,}"
              f"  {time.time() - t0:6.0f}s", flush=True)
    con.close()
    return stats


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, default=DEFAULT_DATA_DIR,
                    help="Directory containing D4N_*.csv files (default: Dropbox local)")
    ap.add_argument("--out", type=Path, default=DEFAULT_THEME_DIR,
                    help="WordPress theme root directory (index at assets/data/)")
    ap.add_argument("--index-file", type=Path,
                    help="Write the index to this path instead of under --out")
    ap.add_argument("--parquet", type=Path,
                    help="D4N_maps.parquet; with --tiles-out, also build the presence tiles")
    ap.add_argument("--tiles-out", type=Path,
                    help="Parent directory of the tiles; they go to <tiles-out>/<version>/")
    ap.add_argument("--threads", type=int, help="DuckDB threads (default: all cores)")
    ap.add_argument("--memory-limit", default="12GB", help="DuckDB memory limit")
    args = ap.parse_args()

    if not args.src.is_dir():
        print(f"error: --src not found: {args.src}", file=sys.stderr)
        return 2
    index_path = args.index_file or (args.out / "assets/data/D4N_species_index.json")
    if not args.index_file and not args.out.is_dir():
        print(f"error: --out not found: {args.out}", file=sys.stderr)
        return 2
    if bool(args.parquet) != bool(args.tiles_out):
        print("error: --parquet and --tiles-out go together", file=sys.stderr)
        return 2
    if args.parquet and not args.parquet.is_file():
        print(f"error: --parquet not found: {args.parquet}", file=sys.stderr)
        return 2

    version = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"version {version}")
    index, species_idx = build_index(args.src, version)

    if args.parquet:
        tiles_dir = args.tiles_out / tile_dir_name(version)
        if tiles_dir.exists() and any(tiles_dir.iterdir()):
            print(f"error: {tiles_dir} is not empty", file=sys.stderr)
            return 2
        print(f"Building tiles into {tiles_dir}")
        st = build_tiles(args.parquet, species_idx, index["n_species"], tiles_dir,
                         threads=args.threads, memory_limit=args.memory_limit)
        print(f"  tiles: {st['tiles']:,}   cells: {st['cells']:,}"
              f" (with no species: {st['empty_cells']:,})"
              f"   dropped parquet species: {st['dropped_species']:,}")
        print(f"  size:  {st['gz_bytes'] / 1e6:.1f} MB gz ({st['raw_bytes'] / 1e6:.1f} MB raw),"
              f" mean {st['gz_bytes'] / max(st['tiles'], 1) / 1024:.1f} KB,"
              f" max {st['gz_max'] / 1024:.1f} KB")

    # The index last: a failed tile build leaves no index pointing at missing tiles.
    write_index(index, index_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
