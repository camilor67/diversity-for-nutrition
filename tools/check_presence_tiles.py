#!/usr/bin/env python3
"""
Check a build of tools/build_species_index.py against the Lambda itself.

For a seeded sample of points the presence tiles must give exactly the species
the Lambda's own cell query returns (extract_suitable_species_parquet in
src/analysis/species_analysis.r: same cell maths, same DuckDB window query),
mapped to the index numbering, for both "Restrict to known range" modes:

    ANY  = present_now == 1
    HULL = present_now == 1 AND within_hull

Points checked:
    - --cells random parquet cells (a random click inside each cell);
    - --points random clicks over the grid's bounding box: where the Lambda's
      query finds no rows the cell must be missing from its tile (the Lambda
      then falls back to the nearest cell), otherwise the sets must match;
    - the user's Colombian point (-73.1665, 2.1581), whose counts are printed.
It also checks the tiles cover every parquet cell exactly once, that their
headers agree with the index, and that each index species' soil list `o`
equals its non-NA category_IDs in D4N_soil_extremes.csv on every row.

Usage:
    python3 tools/check_presence_tiles.py --src DATA/Tables --parquet DATA/D4N_maps.parquet \\
        --index D4N_species_index.json --tiles DIR/<version>
Exits 1 on any mismatch.
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import random
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_species_index import species_numbering  # noqa: E402

RES = 1 / 24
TILE = 12
USER_POINT = (-73.1665, 2.1581)


def decode_tile(path: Path, n_species: int) -> dict[tuple[int, int], tuple[set, set]]:
    """{(local col, local row): (ANY set, HULL set)} — the browser decoder's job, in Python."""
    data = gzip.decompress(path.read_bytes())
    if data[:4] != b"D4NP":
        raise ValueError(f"{path.name}: bad magic")
    fmt, nsp, ncell = struct.unpack_from("<HHH", data, 4)
    if fmt != 1 or nsp != n_species:
        raise ValueError(f"{path.name}: format {fmt}, nSpecies {nsp} (index {n_species})")
    nb = (nsp + 7) // 8
    off, out, prev = 10, {}, None
    for _ in range(ncell):
        lc, lr = data[off], data[off + 1]
        if lc >= TILE or lr >= TILE:
            raise ValueError(f"{path.name}: local cell ({lc},{lr}) out of range")
        if prev is not None and (lr, lc) <= prev:
            raise ValueError(f"{path.name}: cells not in row-major order")
        prev = (lr, lc)
        off += 2
        sets = []
        for _ in range(2):
            bits = data[off:off + nb]
            off += nb
            sets.append({i * 8 + b for i, byte in enumerate(bits) if byte
                         for b in range(8) if byte >> b & 1})
        if max(sets[0] | sets[1], default=-1) >= nsp:
            raise ValueError(f"{path.name}: bit beyond nSpecies")
        out[(lc, lr)] = (sets[0], sets[1])
    if off != len(data):
        raise ValueError(f"{path.name}: {len(data) - off} trailing bytes")
    return out


class Tiles:
    def __init__(self, root: Path, n_species: int):
        self.root, self.n, self.cache = root, n_species, {}

    def lookup(self, lon: float, lat: float):
        """(ANY, HULL) of the cell containing the click, or None if the cell has no data."""
        col = math.floor((lon + 118) * 24)
        row = math.floor((34 - lat) * 24)
        key = (col // TILE, row // TILE)
        if key not in self.cache:
            p = self.root / f"{key[0]}_{key[1]}.bin.gz"
            self.cache[key] = decode_tile(p, self.n) if p.exists() else {}
        return self.cache[key].get((col - key[0] * TILE, row - key[1] * TILE))


def lambda_cell(con, parquet: str, lon: float, lat: float):
    """The Lambda's query_cell() for a click, as rows (species, present_now, within_hull)."""
    cell_lon = -118 + (math.floor((lon + 118) / RES) + 0.5) * RES
    cell_lat = 34 - (math.floor((34 - lat) / RES) + 0.5) * RES
    q = ("SELECT species, present_now, within_hull FROM read_parquet('%s') "
         "WHERE lon BETWEEN %.8f AND %.8f AND lat BETWEEN %.8f AND %.8f" % (
             parquet, cell_lon - RES / 4, cell_lon + RES / 4,
             cell_lat - RES / 4, cell_lat + RES / 4))
    return con.execute(q).fetchall()


def lambda_sets(rows, sidx):
    """Suitable species of the cell in both hull modes, as index numbers (unknown dropped)."""
    any_s = {sidx[sp] for sp, pn, _ in rows if pn == 1 and sp in sidx}
    hull_s = {sidx[sp] for sp, pn, wh in rows if pn == 1 and wh is True and sp in sidx}
    return any_s, hull_s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, required=True, help="Tables/ directory")
    ap.add_argument("--parquet", type=Path, required=True)
    ap.add_argument("--index", type=Path, required=True, help="D4N_species_index.json")
    ap.add_argument("--tiles", type=Path, required=True, help="tile folder of that version")
    ap.add_argument("--cells", type=int, default=400)
    ap.add_argument("--points", type=int, default=200)
    ap.add_argument("--seed", type=int, default=20261024)
    args = ap.parse_args()

    import duckdb

    failures = 0
    index = json.loads(args.index.read_text(encoding="utf-8"))
    n_species = index["n_species"]
    sidx = species_numbering(args.src / "D4N_species_nutrition_data.csv")
    if len(sidx) != n_species:
        print(f"FAIL numbering: {len(sidx)} species in the CSV, index says {n_species}")
        return 1
    if args.tiles.name != index["version"].replace(":", "-"):
        print(f"FAIL tile folder {args.tiles.name} is not the index version {index['version']}")
        failures += 1

    con = duckdb.connect()
    parquet = str(args.parquet)

    # --- soil: `o` per species == the CSV, read independently of the builder.
    soil_rows = con.execute(f"""
        SELECT species, list(DISTINCT CAST(category_ID AS INTEGER) ORDER BY CAST(category_ID AS INTEGER))
        FROM read_csv('{args.src / "D4N_soil_extremes.csv"}', nullstr = ['NA', ''], all_varchar = true)
        WHERE category_ID IS NOT NULL GROUP BY species""").fetchall()
    soil = {sp: ids for sp, ids in soil_rows}
    expect_o = {s: soil.get(sp) for sp, s in sidx.items()}
    seen_o: dict[int, object] = {}
    bad_soil = 0
    for r in index["rows"]:
        s = r["s"]
        if s in seen_o and seen_o[s] != r["o"]:
            bad_soil += 1
        seen_o[s] = r["o"]
        if r["o"] != expect_o[s]:
            bad_soil += 1
    with_soil = sum(1 for v in expect_o.values() if v)
    print(f"soil: {len(seen_o):,} species, {with_soil:,} with categories, mismatches {bad_soil}")
    failures += bad_soil > 0

    # --- coverage: every parquet cell in exactly one tile, nothing else.
    files = sorted(args.tiles.glob("*.bin.gz"))
    tile_cells = 0
    for p in files:
        with gzip.open(p) as fh:
            head = fh.read(10)
        if head[:4] != b"D4NP":
            print(f"FAIL {p.name}: bad magic")
            failures += 1
            continue
        tile_cells += struct.unpack_from("<H", head, 8)[0]
    n_cells, n_tiles = con.execute(f"""
        SELECT count(*), count(DISTINCT (c // 12, r // 12)) FROM (
          SELECT DISTINCT CAST(round((lon + 118) * 24 - 0.5) AS INTEGER) c,
                          CAST(round((34 - lat) * 24 - 0.5) AS INTEGER) r
          FROM read_parquet('{parquet}'))""").fetchone()
    ok = tile_cells == n_cells and len(files) == n_tiles
    print(f"coverage: {len(files):,} tiles / {tile_cells:,} cells; parquet {n_tiles:,} tiles /"
          f" {n_cells:,} cells -> {'ok' if ok else 'FAIL'}")
    failures += not ok

    tiles = Tiles(args.tiles, n_species)
    rng = random.Random(args.seed)

    def check(lon, lat, label, verbose=False):
        rows = lambda_cell(con, parquet, lon, lat)
        got = tiles.lookup(lon, lat)
        if not rows:
            if got is not None:
                print(f"FAIL {label} ({lon:.5f},{lat:.5f}): Lambda finds no rows, tile has the cell")
                return False, None
            return True, None
        if got is None:
            print(f"FAIL {label} ({lon:.5f},{lat:.5f}): Lambda finds {len(rows)} rows, tile lacks the cell")
            return False, None
        want = lambda_sets(rows, sidx)
        if got[0] != want[0] or got[1] != want[1]:
            print(f"FAIL {label} ({lon:.5f},{lat:.5f}): ANY {len(got[0])} vs {len(want[0])},"
                  f" HULL {len(got[1])} vs {len(want[1])}")
            return False, None
        return True, (want, rows)

    # --- random parquet cells, clicked anywhere inside the cell.
    cells = con.execute(f"SELECT DISTINCT lon, lat FROM read_parquet('{parquet}') ORDER BY lon, lat").fetchall()
    sample = rng.sample(cells, args.cells)
    bad = nonempty = 0
    for lon, lat in sample:
        clon = lon + rng.uniform(-0.45, 0.45) * RES
        clat = lat + rng.uniform(-0.45, 0.45) * RES
        good, res = check(clon, clat, "cell")
        bad += not good
        nonempty += bool(res and res[0][0])
    print(f"random cells: {args.cells} checked ({nonempty} with species), mismatches {bad}")
    failures += bad

    # --- random clicks over the bounding box (includes sea/no-data cells).
    lo_lon, hi_lon, lo_lat, hi_lat = con.execute(
        f"SELECT min(lon), max(lon), min(lat), max(lat) FROM read_parquet('{parquet}')").fetchone()
    bad = empty = 0
    for _ in range(args.points):
        good, res = check(rng.uniform(lo_lon, hi_lon), rng.uniform(lo_lat, hi_lat), "point")
        bad += not good
        empty += good and res is None
    print(f"random points: {args.points} checked ({empty} without data -> fallback), mismatches {bad}")
    failures += bad

    # --- the user's point.
    lon, lat = USER_POINT
    good, res = check(lon, lat, "user point")
    failures += not good
    if res:
        (any_s, hull_s), rows = res
        p_any = len({sp for sp, pn, _ in rows if pn == 1})
        p_hull = len({sp for sp, pn, wh in rows if pn == 1 and wh is True})
        print(f"user point ({lon}, {lat}): ANY {len(any_s):,} / HULL {len(hull_s):,} index species"
              f" (parquet species: {p_any:,} / {p_hull:,}) -> {'ok' if good else 'FAIL'}")

    print("ALL OK" if failures == 0 else f"{failures} FAILURE(S)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
