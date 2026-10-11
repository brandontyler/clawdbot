#!/usr/bin/env python3
"""
denton-crime-watch.py — pull Denton PD offense reports for a verified nearby
street/hundred-block set and build a scheduled digest.

Data source: City of Denton open-data CKAN datastore (Denton PD crime reports).
  - Coverage verified 2026-08-15: 78,914 records, 2019-11-06 -> present.
  - Refreshed ~daily. Addresses are masked to the hundred-block (for example,
    "5XX HEADLEE ST").
  - Fields: _id, ID, Agency, Crime, Date/Time, Public_Address.
  - This is an OFFENSE-report set, not calls-for-service. Non-crime responses do
    not appear. Exact-house detail requires a Texas Public Information Act request.

Usage:
  denton-crime-watch.py --scope home         --days 365
  denton-crime-watch.py --scope neighborhood --days 30 --json
  denton-crime-watch.py --scope city         --days 7
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
import urllib.parse
import urllib.request
from collections.abc import Mapping

CKAN = "https://data.cityofdenton.com/api/3/action/datastore_search_sql"
RESOURCE_ID = "34f60f26-b458-48d0-9e40-d4f83fee3563"

# The public offense data has no coordinates or exact addresses. On 2026-09-21,
# the configured home point was resolved through OpenStreetMap Nominatim, every
# masked block seen for the candidate residential streets was represented by its
# midpoint address (for example, 20XX -> 2050), and great-circle distance was
# measured from the configured home point. Keep representatives <=700 m. A
# boundary block is approximate because the City suppresses the exact house.
# Unknown/new blocks fail closed until their representative is verified.
HOME_BLOCKS: dict[str, frozenset[int]] = {"HEADLEE ST": frozenset({400})}
MAX_NEIGHBORHOOD_BLOCK_DISTANCE_M = 700.0
BLOCK_REPRESENTATIVE_DISTANCE_M: dict[tuple[str, int], float] = {
    ("HEADLEE ST", 400): 42.2,
    ("HEADLEE ST", 500): 204.4,
    ("HEADLEE ST", 600): 388.8,
    ("HEADLEE ST", 700): 546.9,
    ("HINKLE DR", 2500): 636.3,
    ("FAIN ST", 300): 396.7,
    ("DENISON ST", 2000): 680.2,
    ("DENISON ST", 2100): 616.4,
    ("DENISON ST", 2200): 517.6,
    ("DENISON ST", 2300): 432.5,
    ("DENISON ST", 2400): 329.9,
    ("DENISON ST", 2500): 258.9,
    ("DENISON ST", 2600): 210.2,
    ("NORTHRIDGE ST", 300): 347.6,
    ("NORTHRIDGE ST", 400): 292.2,
    ("NORTHRIDGE ST", 500): 356.1,
    ("NORTHRIDGE ST", 600): 492.5,
    ("NORTHRIDGE ST", 700): 623.8,
    ("OAKHILL DR", 400): 95.8,
    ("OAKHILL DR", 500): 131.9,
    ("MIMOSA DR", 300): 199.9,
    ("MIMOSA DR", 400): 91.5,
    ("MIMOSA DR", 500): 220.7,
    ("MIMOSA DR", 600): 401.5,
    ("MIMOSA DR", 700): 555.3,
    ("STRATA DR", 400): 199.3,
    ("STRATA DR", 500): 279.8,
    ("MAGNOLIA ST", 300): 269.8,
    ("MAGNOLIA ST", 400): 197.8,
    ("MAGNOLIA ST", 500): 279.1,
    ("MAGNOLIA ST", 600): 437.2,
    ("MAGNOLIA ST", 700): 579.1,
}
if any(
    distance > MAX_NEIGHBORHOOD_BLOCK_DISTANCE_M
    for distance in BLOCK_REPRESENTATIVE_DISTANCE_M.values()
):
    raise RuntimeError("configured neighborhood block exceeds the 700 m boundary")

NEIGHBORHOOD_BLOCKS: dict[str, frozenset[int]] = {
    street: frozenset(
        block
        for candidate_street, block in BLOCK_REPRESENTATIVE_DISTANCE_M
        if candidate_street == street
    )
    for street in sorted({street for street, _ in BLOCK_REPRESENTATIVE_DISTANCE_M})
}
STREET_SUFFIX_ALIASES = {
    "STREET": "ST",
    "DRIVE": "DR",
    "LANE": "LN",
    "ROAD": "RD",
    "BOULEVARD": "BLVD",
    "COURT": "CT",
}
# One malformed City row says HINKLE RD; map it to the actual Hinkle Drive only
# after exact parsing. This does not allow HINKLEY OAK DR.
STREET_ALIASES = {"HINKLE RD": "HINKLE DR"}


def sql_query(sql: str, timeout: float = 20.0) -> list[dict]:
    url = CKAN + "?" + urllib.parse.urlencode({"sql": sql})
    req = urllib.request.Request(url, headers={"User-Agent": "denton-crime-watch/2.0"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        data = json.load(response)
    if not data.get("success"):
        raise RuntimeError(f"CKAN error: {json.dumps(data)[:300]}")
    return data["result"]["records"]


def normalize_street(raw: str) -> str:
    street = re.sub(r"[^A-Z0-9 ]+", " ", raw.upper())
    tokens = street.split()
    if tokens and tokens[-1] in STREET_SUFFIX_ALIASES:
        tokens[-1] = STREET_SUFFIX_ALIASES[tokens[-1]]
    normalized = " ".join(tokens)
    return STREET_ALIASES.get(normalized, normalized)


def parse_masked_address(public_address: str) -> tuple[str, int] | None:
    """Return canonical street and numeric hundred-block, or None if suppressed."""
    address = re.sub(r"\s+", " ", public_address.strip().upper())
    address = re.sub(r"\s+DENTON\s+TX(?:\s+TX)?$", "", address)
    match = re.fullmatch(r"(\d+)XX\s+(.+)", address)
    if not match:
        return None
    block = int(match.group(1)) * 100
    return normalize_street(match.group(2)), block


def address_allowed(public_address: str, allowed: Mapping[str, frozenset[int]]) -> bool:
    parsed = parse_masked_address(public_address)
    if parsed is None:
        return False
    street, block = parsed
    return block in allowed.get(street, frozenset())


def street_query_fragments(allowed: Mapping[str, frozenset[int]]) -> list[str]:
    suffixes = {"ST", "DR", "LN", "RD", "BLVD", "CT"}
    return sorted(
        " ".join(street.split()[:-1]) if street.split()[-1] in suffixes else street
        for street in allowed
    )


def like_clause(streets: list[str]) -> str:
    parts = []
    for street in streets:
        escaped = street.upper().replace("'", "")
        parts.append(f'"Public_Address" LIKE \'%{escaped}%\'')
    return "(" + " OR ".join(parts) + ")"


def fetch(
    allowed: Mapping[str, frozenset[int]] | None,
    since: str,
    *,
    timeout: float = 20.0,
) -> list[dict]:
    where = [f'"Date/Time" >= \'{since}\'']
    if allowed is not None:
        where.append(like_clause(street_query_fragments(allowed)))
    sql = (
        f'SELECT "Date/Time","Crime","Public_Address" FROM "{RESOURCE_ID}" '
        f'WHERE {" AND ".join(where)} ORDER BY "Date/Time" DESC LIMIT 1000'
    )
    records = sql_query(sql, timeout=timeout)
    if allowed is None:
        return records
    return [row for row in records if address_allowed(row["Public_Address"], allowed)]


def format_block_ranges(allowed: Mapping[str, frozenset[int]]) -> list[str]:
    labels: list[str] = []
    for street, blocks in sorted(allowed.items()):
        ordered = sorted(blocks)
        runs: list[tuple[int, int]] = []
        for block in ordered:
            if not runs or block != runs[-1][1] + 100:
                runs.append((block, block))
            else:
                runs[-1] = (runs[-1][0], block)
        formatted = ",".join(
            f"{start // 100}XX" if start == end else f"{start // 100}XX-{end // 100}XX"
            for start, end in runs
        )
        labels.append(f"{formatted} {street}")
    return labels


def build_report(scope: str, days: int, *, fetch_timeout: float = 20.0) -> dict:
    since = (dt.date.today() - dt.timedelta(days=days)).isoformat()
    allowed = {
        "home": HOME_BLOCKS,
        "neighborhood": NEIGHBORHOOD_BLOCKS,
        "city": None,
    }[scope]
    records = fetch(allowed, since, timeout=fetch_timeout)
    by_type: dict[str, int] = {}
    for row in records:
        by_type[row["Crime"]] = by_type.get(row["Crime"], 0) + 1
    return {
        "scope": scope,
        "streets": sorted(allowed) if allowed is not None else None,
        "block_ranges": format_block_ranges(allowed) if allowed is not None else None,
        "filter_method": "exact parsed street + verified hundred-block" if allowed is not None else "citywide",
        "maximum_block_representative_distance_m": (
            MAX_NEIGHBORHOOD_BLOCK_DISTANCE_M if scope == "neighborhood" else None
        ),
        "since": since,
        "generated": dt.datetime.now().isoformat(timespec="seconds"),
        "total": len(records),
        "by_type": dict(sorted(by_type.items(), key=lambda item: -item[1])),
        "incidents": records,
    }


def render(report: dict) -> str:
    lines: list[str] = []
    scope_label = {
        "home": "your block",
        "neighborhood": "your neighborhood",
        "city": "Denton (citywide)",
    }[report["scope"]]
    lines.append(
        f"🚔 Denton crime — {scope_label} — since {report['since']} ({report['total']} reports)"
    )
    if report["block_ranges"]:
        lines.append(f"   verified blocks: {', '.join(report['block_ranges'])}")
    if report["by_type"]:
        lines.append(
            "   by type: "
            + ", ".join(f"{name} ({count})" for name, count in report["by_type"].items())
        )
    lines.append("")
    for row in report["incidents"][:40]:
        lines.append(
            f"   {row['Date/Time']:16}  {row['Crime']:22}  {row['Public_Address'].strip()}"
        )
    if report["total"] > 40:
        lines.append(f"   … and {report['total'] - 40} more")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--scope", choices=["home", "neighborhood", "city"], default="neighborhood"
    )
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--fetch-timeout", type=float, default=20.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.days < 1:
        parser.error("--days must be positive")
    if not 0 < args.fetch_timeout <= 30:
        parser.error("--fetch-timeout must be greater than 0 and at most 30 seconds")
    report = build_report(args.scope, args.days, fetch_timeout=args.fetch_timeout)
    print(json.dumps(report, indent=1) if args.json else render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
