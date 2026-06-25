#!/usr/bin/env python3
"""
commute-briefing.py — Daily "What's Broken on Your Drive" briefing.

Pulls live closure/incident data from:
  1. DriveTexas (TxDOT statewide) MapLarge API
  2. TxDOT I-35E Phase 2 official closures page

Filters to Brandon's Denton ↔ Dallas Galleria commute corridor:
  - I-35E (IH0035E) in Dallas County (57) and Denton County (61)
  - I-635 (IH0635) WEST side only (excluding East Project zone past US-75)
  - FM-1171 in Denton County (Lewisville crossings)

Posts a concise Discord summary to #openclaw-ec2.

Schedule: weekdays 5:30am CDT via systemd timer.
"""

from __future__ import annotations

import codecs
import gzip
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

# ─── Config ──────────────────────────────────────────────────────────────
CDT = timezone(timedelta(hours=-5))  # CDT (DST), close enough for a briefing
DISCORD_CHANNEL_ID = os.environ.get("COMMUTE_DISCORD_CHANNEL", "1503414103341797406")  # #openclaw-ec2

def _load_discord_token() -> str:
    """Discord bot token: env var first, else .channels.discord.token from openclaw.json."""
    if os.environ.get("DISCORD_BOT_TOKEN"):
        return os.environ["DISCORD_BOT_TOKEN"]
    cfg_path = os.path.expanduser("~/.openclaw/openclaw.json")
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
        return ((cfg.get("channels") or {}).get("discord") or {}).get("token", "") or ""
    except Exception:
        return ""

DISCORD_TOKEN = _load_discord_token()

DRIVETEXAS_API = "https://dtx-e-cdn.maplarge.com/Api/ProcessDirect"
TXDOT_PHASE2_URL = "https://www.txdot.gov/35ephase2/road-closures.html"

# County codes
DALLAS_CO = 57
DENTON_CO = 61

# Routes Brandon's commute crosses
ROUTE_IH35E = "IH0035E"
ROUTE_IH635 = "IH0635"
ROUTE_FM1171 = "FM1171"

# I-635 East Project landmarks — exclude from the briefing (not on Brandon's route)
EAST_PROJECT_NOISE = ["IH0030", "US0080", "Town East", "Towne Centre", "Gross Rd", "Mesquite"]

TYPECODES = {
    "C": "🚧 Construction",
    "A": "💥 Accident",
    "M": "🔧 Maintenance",
    "O": "⚠️ Other",
    "D": "🪨 Damage",
    "F": "🌊 Flooding",
    "I": "❄️ Ice/Snow",
    "X": "🚫 Closed",
}

# ─── DriveTexas query ────────────────────────────────────────────────────
def dtx_query(table: str, where_clauses: list, take: int = 200) -> dict:
    """Query the MapLarge backend directly. Returns parsed JSON."""
    req = {
        "action": "table/query",
        "query": {
            "table": f"appgeo/{table}",
            "sqlselect": [
                "RTENM", "TRVLDRCTCD", "CONDDSCR", "CONDLMTFROMDSCR",
                "CONDLMTTODSCR", "CONDSTARTTS", "CONDENDTS", "CNSTRNTTYPECD",
                "TXDOTCOUNTYNBR",
            ],
            "start": 0, "take": take, "where": where_clauses,
        },
    }
    qs = urllib.parse.urlencode({"request": json.dumps(req)})
    url = f"{DRIVETEXAS_API}?{qs}"
    rq = urllib.request.Request(url, headers={"Accept-Encoding": "gzip"})
    with urllib.request.urlopen(rq, timeout=20) as r:
        raw = r.read()
        if r.headers.get("content-encoding") == "gzip":
            raw = gzip.decompress(raw)
        if raw.startswith(codecs.BOM_UTF8):
            raw = raw[3:]
        return json.loads(raw)


# ─── Google Maps live travel time scrape ────────────────────────────────
def fetch_live_travel_time(origin: str, destination: str, depart_unix: int | None = None) -> dict:
    """Scrape drive-time from Google Maps via dev-browser. Returns {minutes, distance_mi, alt_minutes, raw}.
    If depart_unix is provided, uses depart-at forecast (Google's historical-traffic prediction for that time).
    Otherwise uses 'now' which is current live traffic."""
    import subprocess
    if depart_unix:
        url = (f"https://www.google.com/maps?saddr={urllib.parse.quote(origin)}"
               f"&daddr={urllib.parse.quote(destination)}&dirflg=d&ttype=dep&t={depart_unix}")
    else:
        url = f"https://www.google.com/maps/dir/{urllib.parse.quote(origin)}/{urllib.parse.quote(destination)}/"
    js = f'''
const page = await browser.newPage();
await page.setViewportSize({{ width: 1280, height: 900 }});
await page.goto({json.dumps(url)}, {{ waitUntil: "domcontentloaded", timeout: 30000 }});
await page.waitForTimeout(13000);
const text = await page.evaluate(() => document.body.innerText);
const ranges = text.match(/\\d+\\s*hr\\s*\\d+\\s*min|\\d+\\s*min/g) || [];
const dist = text.match(/\\d+(\\.\\d+)?\\s*mi/g) || [];
console.log(JSON.stringify({{times: ranges.slice(0, 6), dist: dist.slice(0, 3)}}));
await page.close();
'''
    try:
        result = subprocess.run(
            ["dev-browser", "--headless", "--timeout", "60"],
            input=js, capture_output=True, text=True, timeout=90,
        )
        # Extract the JSON line we logged
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("{") and "times" in line:
                parsed = json.loads(line)
                times = parsed.get("times", [])
                # Filter out >2hr (those are walking/transit; drives are <2hr from Denton to Dallas)
                drive_mins = []
                for t in times:
                    m = re.match(r"(\d+)\s*hr\s*(\d+)\s*min", t)
                    if m:
                        total = int(m.group(1)) * 60 + int(m.group(2))
                        if total < 120: drive_mins.append(total)
                    else:
                        m = re.match(r"(\d+)\s*min", t)
                        if m: drive_mins.append(int(m.group(1)))
                drive_mins = drive_mins[:5]
                if not drive_mins: return {"error": "no-times"}
                return {
                    "minutes": min(drive_mins),
                    "alt_minutes": sorted(drive_mins),
                    "distance_mi": parsed.get("dist", [None])[0],
                }
        return {"error": "no-output", "stderr": result.stderr[:200]}
    except Exception as e:
        return {"error": str(e)[:200]}


def fetch_route_conditions(table: str, route: str, county: int) -> list[dict]:
    """Fetch all conditions for a route in one county. Returns flat list of dicts."""
    where = [[
        {"col": "RTENM", "test": "Equal", "value": route},
        {"col": "TXDOTCOUNTYNBR", "test": "Equal", "value": county},
    ]]
    res = dtx_query(table, where, take=100)
    data = res.get("data", {}).get("data", {})
    n = len(data.get("RTENM", []))
    rows = []
    for i in range(n):
        rows.append({k: data[k][i] for k in data if isinstance(data[k], list) and len(data[k]) > i})
    return rows


def is_brandons_route(row: dict) -> bool:
    """Filter out conditions that aren't on Brandon's actual route."""
    text = " ".join([row.get(k) or "" for k in ("CONDDSCR", "CONDLMTFROMDSCR", "CONDLMTTODSCR")])
    # I-35E in either county = always relevant — UNLESS it references IH-30 (south of his route)
    if row["RTENM"] == ROUTE_IH35E:
        return "IH0030" not in text
    # FM1171 (Lewisville) = relevant
    if row["RTENM"] == ROUTE_FM1171:
        return True
    # I-635: only western section. Exclude East Project noise.
    if row["RTENM"] == ROUTE_IH635:
        return not any(noise in text for noise in EAST_PROJECT_NOISE)
    return True


def fmt_when(start_ms: int, end_ms: int) -> str:
    """Format start→end timestamps as a human-readable range."""
    def fmt(ms):
        if not ms or ms < 1e10: return ""
        return datetime.fromtimestamp(ms / 1000, tz=CDT).strftime("%a %m/%d %-I:%M%p")
    s, e = fmt(start_ms), fmt(end_ms)
    if s and e: return f"{s} → {e}"
    return s or e or "ongoing"


def is_relevant_window(row: dict, now: datetime) -> bool:
    """Keep only conditions active today or in the next 24h, excluding multi-month permanents."""
    end_ms = row.get("CONDENDTS") or 0
    start_ms = row.get("CONDSTARTTS") or 0
    end_dt = datetime.fromtimestamp(end_ms / 1000, tz=CDT) if end_ms > 1e10 else None
    start_dt = datetime.fromtimestamp(start_ms / 1000, tz=CDT) if start_ms > 1e10 else None
    cutoff = now + timedelta(hours=24)
    # Skip "permanent" closures running >60 days — they're known long-term and noise here
    if start_dt and end_dt and (end_dt - start_dt) > timedelta(days=60):
        return False
    # Active right now
    if start_dt and start_dt <= now and (not end_dt or end_dt > now):
        return True
    # Or starting in the next 24h
    if start_dt and now <= start_dt <= cutoff:
        return True
    return False


def clean_desc(desc: str) -> str:
    """Strip HTML tags + collapse whitespace from condition descriptions."""
    if not desc:
        return ""
    desc = desc.replace("<br/>", " | ").replace("<br />", " | ")
    desc = re.sub(r"<[^>]+>", "", desc)
    desc = re.sub(r"\s*\|\s*\|\s*", " | ", desc)
    desc = re.sub(r"\s+", " ", desc).strip(" |")
    return desc


# ─── TxDOT 35EPhase2 scraper ─────────────────────────────────────────────
def fetch_phase2_closures() -> dict:
    """Scrape the TxDOT 35EPhase2 closures page. Returns structured sections."""
    rq = urllib.request.Request(TXDOT_PHASE2_URL, headers={"Accept-Encoding": "gzip"})
    with urllib.request.urlopen(rq, timeout=20) as r:
        raw = r.read()
        if r.headers.get("content-encoding") == "gzip":
            raw = gzip.decompress(raw)
        html = raw.decode("utf-8", errors="replace")
    # Extract the body text — strip HTML, keep paragraphs
    body = re.sub(r"<script[^>]*>.*?</script>", "", html, flags=re.DOTALL)
    body = re.sub(r"<style[^>]*>.*?</style>", "", body, flags=re.DOTALL)
    body = re.sub(r"<[^>]+>", "\n", body)
    lines = [re.sub(r"\s+", " ", l).strip() for l in body.split("\n")]
    lines = [l for l in lines if l]

    sections = {}
    current = None
    section_headers = ["Overnight closures", "Nightly closures", "Nighttime closures",
                       "Daytime closures", "Short-term closures", "Long-term closures",
                       "Permanent closures"]
    for line in lines:
        if line in section_headers:
            current = line
            sections[current] = []
        elif current and line and not line.startswith(("Closures are subject", "Below is a list")):
            # Filter for actual closure lines (start with "The" or "All" or "Northbound"/"Southbound")
            if re.match(r"^(The |All |Northbound |Southbound |[A-Z][A-Za-z\- ]+ I-35E)", line):
                sections[current].append(line)
    return sections


def is_daytime_construction(row: dict, now: datetime) -> bool:
    """For construction items, keep only ones active during Brandon's commute hours (6am-9pm) today/tomorrow.
    Drops overnight nightly closures (8pm-6am)."""
    end_ms = row.get("CONDENDTS") or 0
    start_ms = row.get("CONDSTARTTS") or 0
    if start_ms < 1e10 or end_ms < 1e10: return False
    start_dt = datetime.fromtimestamp(start_ms / 1000, tz=CDT)
    end_dt = datetime.fromtimestamp(end_ms / 1000, tz=CDT)
    # Description text: most "nightly closure" items contain that exact phrase
    desc = (row.get("CONDDSCR") or "").lower()
    if "nighttime closure" in desc or "night work only" in desc or "nightly closure" in desc:
        return False
    # If start hour is >=20 (8pm) and end hour is <=6 (6am), it's overnight — drop
    if start_dt.hour >= 20 and end_dt.hour <= 6: return False
    return True


# ─── Format the briefing ─────────────────────────────────────────────────
def build_briefing(now: datetime) -> str:
    """Compose the Discord message body."""
    out = []
    weekday = now.strftime("%A, %B %-d %Y")
    time_str = now.strftime("%-I:%M %p CDT")
    out.append(f"🛣️ **Commute Briefing — {weekday} · {time_str}**")
    out.append("")

    # ── Section 1: LIVE travel time (the #1 thing that matters) ──
    # Brandon's commute pattern: Mon/Tue/Wed only. Outbound 6:00am, inbound 3:15pm.
    # On commute days, forecast for actual departure. On non-commute days, skip forecast.
    weekday_idx = now.weekday()  # Mon=0 ... Sun=6
    is_commute_day = weekday_idx in (0, 1, 2)  # Mon, Tue, Wed

    if is_commute_day:
        out.append("**🚗 Forecast for today's commute (Brady + Brandon, M/T/W)**")
        # Build depart timestamps for today's 6:00am and 3:15pm
        out_dt = now.replace(hour=6, minute=0, second=0, microsecond=0)
        in_dt = now.replace(hour=15, minute=15, second=0, microsecond=0)
        # If we're past those times today, push to next-occurrence (i.e., the briefing was triggered late)
        if now > out_dt + timedelta(hours=1): out_dt += timedelta(days=1)
        if now > in_dt + timedelta(hours=1): in_dt += timedelta(days=1)
        out_unix = int(out_dt.timestamp())
        in_unix = int(in_dt.timestamp())
        # Baselines: 6am outbound is light traffic (~35 min). 3:15pm inbound is pre-rush (~40 min).
        legs = [
            ("Denton → Galleria @ 6:00 AM", "Denton, TX", "Galleria Dallas, TX", out_unix, 35),
            ("Galleria → Denton @ 3:15 PM", "Galleria Dallas, TX", "Denton, TX", in_unix, 40),
        ]
        for label, origin, dest, ts, baseline in legs:
            leg = fetch_live_travel_time(origin, dest, depart_unix=ts)
            if "error" in leg:
                out.append(f"• {label}: _scrape failed: {leg['error']}_")
                continue
            mins = leg["minutes"]
            alts = leg["alt_minutes"]
            dist = leg.get("distance_mi") or "?"
            delta = mins - baseline
            if delta >= 10: delta_str = f" 🔴 +{delta} vs typical"
            elif delta >= 5: delta_str = f" 🟡 +{delta} vs typical"
            elif delta <= -2: delta_str = f" 🟢 −{-delta} below typical"
            else: delta_str = " ✅ at typical"
            alt_str = f"  _(alts: {', '.join(str(a)+'min' for a in alts[1:4])})_" if len(alts) > 1 else ""
            out.append(f"• {label}: **{mins} min** · {dist}{delta_str}{alt_str}")
    else:
        # Thu-Sun: no scheduled commute. Show live "right now" as a courtesy in case ad-hoc trip.
        day_name = now.strftime("%A")
        out.append(f"**🚗 Live travel time (right now — {day_name} is not a commute day)**")
        for label, origin, dest in (
            ("Denton → Galleria", "Denton, TX", "Galleria Dallas, TX"),
            ("Galleria → Denton", "Galleria Dallas, TX", "Denton, TX"),
        ):
            leg = fetch_live_travel_time(origin, dest)
            if "error" in leg:
                out.append(f"• {label}: _scrape failed: {leg['error']}_")
                continue
            mins = leg["minutes"]
            dist = leg.get("distance_mi") or "?"
            out.append(f"• {label}: **{mins} min** · {dist}")
    out.append("")

    # ── Section 2: Live incidents on route (last 6h, all type codes) ──
    all_rows = []
    for table in ("conditionsLine", "futureConditionsLine", "conditionsPoint"):
        for route in (ROUTE_IH35E, ROUTE_IH635, ROUTE_FM1171):
            for county in (DALLAS_CO, DENTON_CO):
                try:
                    rows = fetch_route_conditions(table, route, county)
                    for r in rows:
                        r["_table"] = table
                    all_rows.extend(rows)
                except Exception as e:
                    print(f"  [warn] dtx {table}/{route}/{county}: {e}", file=sys.stderr)

    # Dedupe
    seen = set()
    unique = []
    for r in all_rows:
        key = (r.get("CONDSTARTTS"), r.get("CONDLMTFROMDSCR"), (r.get("CONDDSCR") or "")[:50])
        if key in seen: continue
        seen.add(key)
        if is_brandons_route(r) and is_relevant_window(r, now):
            unique.append(r)
    unique.sort(key=lambda r: (r.get("CONDSTARTTS") or 0))

    # Split: real incidents (A/D/X/F = wrecks/closures/floods) vs construction (C/M)
    incident_codes = {"A", "D", "X", "F", "I"}
    incidents = [r for r in unique if r.get("CNSTRNTTYPECD") in incident_codes]
    construction = [r for r in unique if r.get("CNSTRNTTYPECD") not in incident_codes and is_daytime_construction(r, now)]

    if incidents:
        out.append(f"**🚨 Active incidents on your route ({len(incidents)})**")
        for r in incidents[:8]:
            t = TYPECODES.get(r.get("CNSTRNTTYPECD", ""), "❓")
            route_name = r["RTENM"].replace("IH00", "I-").replace("FM", "FM-")
            direction = r.get("TRVLDRCTCD", "")
            when = fmt_when(r.get("CONDSTARTTS", 0), r.get("CONDENDTS", 0))
            from_loc = (r.get("CONDLMTFROMDSCR") or "")[:60]
            desc = clean_desc(r.get("CONDDSCR") or "")[:140]
            out.append(f"• {t} **{route_name} {direction}** — {when}")
            out.append(f"   📍 {from_loc}")
            if desc: out.append(f"   _{desc}_")
    else:
        out.append("**🚨 Active incidents on your route: none** ✅")
    out.append("")

    # ── Section 3: Daytime construction (overnight stuff filtered out) ──
    if construction:
        out.append(f"**🚧 Daytime construction touching your commute ({len(construction)})**")
        for r in construction[:6]:
            route_name = r["RTENM"].replace("IH00", "I-").replace("FM", "FM-")
            direction = r.get("TRVLDRCTCD", "")
            when = fmt_when(r.get("CONDSTARTTS", 0), r.get("CONDENDTS", 0))
            from_loc = (r.get("CONDLMTFROMDSCR") or "")[:60]
            desc = clean_desc(r.get("CONDDSCR") or "")[:120]
            out.append(f"• **{route_name} {direction}** — {when}")
            out.append(f"   📍 {from_loc}")
            if desc: out.append(f"   _{desc}_")
        if len(construction) > 6:
            out.append(f"   _+{len(construction) - 6} more · full list at https://drivetexas.org_")
    else:
        out.append("**🚧 No daytime construction on your route** ✅")

    out.append("")
    out.append("_Live travel time: Google Maps · Incidents: TxDOT DriveTexas · Updates Mon-Fri 5:30am CDT_")
    return "\n".join(out)


# ─── Discord post ────────────────────────────────────────────────────────
def post_to_discord(message: str) -> dict:
    """Post the briefing as a Discord message."""
    if not DISCORD_TOKEN:
        print("[ERROR] DISCORD_BOT_TOKEN not set. Printing message instead:\n", file=sys.stderr)
        print(message)
        return {"dry_run": True}
    # Discord caps individual messages at 2000 chars; split if needed
    chunks = []
    while message:
        if len(message) <= 1990:
            chunks.append(message)
            break
        cut = message.rfind("\n", 0, 1990)
        if cut < 0: cut = 1990
        chunks.append(message[:cut])
        message = message[cut:].lstrip("\n")
    results = []
    url = f"https://discord.com/api/v10/channels/{DISCORD_CHANNEL_ID}/messages"
    for chunk in chunks:
        body = json.dumps({"content": chunk}).encode("utf-8")
        rq = urllib.request.Request(url, data=body, method="POST", headers={
            "Authorization": f"Bot {DISCORD_TOKEN}",
            "Content-Type": "application/json",
            "User-Agent": "DiscordBot (https://github.com/brandontyler/clawdbot, commute-briefing/1.0)",
        })
        with urllib.request.urlopen(rq, timeout=20) as r:
            results.append({"status": r.status, "body": r.read()[:200].decode("utf-8", errors="replace")})
    return {"chunks": len(chunks), "results": results}


# ─── Main ────────────────────────────────────────────────────────────────
def main():
    now = datetime.now(tz=CDT)
    msg = build_briefing(now)
    if "--dry-run" in sys.argv:
        print(msg)
        return 0
    res = post_to_discord(msg)
    print(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
