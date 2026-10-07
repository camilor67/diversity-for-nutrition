#!/usr/bin/env python3
"""
Build a slim species index for the WordPress tool's client-side
"impossible combinations" feature (match preview + facet counts).

Reads:
    - D4N_species_nutrition_data.csv   (one row per species × plant_part × food_group × growth_form)
    - D4N_plant_parts.csv              (ID -> text)
    - D4N_food_groups.csv              (ID -> text)
    - D4N_growth_forms.csv             (ID -> text)
    - D4N_species_types.csv            (ID -> text, where text is "wild"/"cultivated")

Writes:
    - <theme>/assets/data/D4N_species_index.json

Index shape (row-level, denormalized — matches R's filter_species semantics):
    {
        "version": "<utc-iso>",
        "rows": [
            {"s": <species_idx>, "p": <part_id|null>, "g": <group_id|null>,
             "f": <[form_id, ...]|null>, "t": <type_id|null>, "tent": <bool>},
            ...
        ]
    }

`f` is a list because growth_form may combine multiple sources with "/"
(e.g. "shrub/tree" = some sources classify it as shrub, others as tree).
The client matches if the user's selection intersects this list.

`s` is a 0-based species index assigned by first-seen order — used only for
distinct counting on the client; species names are not shipped (smaller payload,
no PII concerns).

Usage:
    python3 tools/build_species_index.py [--src DATA_DIR] [--out THEME_DIR]

Defaults assume the local Dropbox layout and the camilo Local WP theme path.
Re-run whenever the upstream CSV changes.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
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


def build_index(src: Path, theme: Path) -> dict:
    plant_parts = load_lookup(src / "D4N_plant_parts.csv", "plant_part")
    food_groups = load_lookup(src / "D4N_food_groups.csv", "food_group")
    growth_forms = load_lookup(src / "D4N_growth_forms.csv", "growth_form")
    species_types = load_lookup(src / "D4N_species_types.csv", "species_type")

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
            })

    out = {
        "version": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "n_species": len(species_idx),
        "n_rows": len(rows),
        "rows": rows,
    }

    out_path = theme / "assets/data/D4N_species_index.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        # Compact (no whitespace) — saves ~30% on disk and gzip works well anyway.
        json.dump(out, f, separators=(",", ":"), ensure_ascii=False)

    print(f"Wrote {out_path}")
    print(f"  species: {out['n_species']:,}   rows: {out['n_rows']:,}   skipped: {skipped:,}")
    print(f"  size:    {out_path.stat().st_size / 1024:.1f} KB")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, default=DEFAULT_DATA_DIR,
                    help="Directory containing D4N_*.csv files (default: Dropbox local)")
    ap.add_argument("--out", type=Path, default=DEFAULT_THEME_DIR,
                    help="WordPress theme root directory")
    args = ap.parse_args()

    if not args.src.is_dir():
        print(f"error: --src not found: {args.src}", file=sys.stderr)
        return 2
    if not args.out.is_dir():
        print(f"error: --out not found: {args.out}", file=sys.stderr)
        return 2

    build_index(args.src, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
