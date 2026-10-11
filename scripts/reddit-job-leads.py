#!/usr/bin/env python3
"""Discover actionable Reddit job leads for the active job-search profiles.

Fetches one Reddit Atom search request per invocation and writes JSONL to stdout.
Pass an Atom file for deterministic validation without a network request.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

SEARCH_URL = "https://www.reddit.com/search.rss"
USER_AGENT = "linux:openclaw.job-search:v1.0 (by /u/BrandonTyler)"
ATOM_NS = {"atom": "http://www.w3.org/2005/Atom"}

ACTION_RE = re.compile(
    r"\[(?:hiring|paid)\]|\b(?:now\s+)?hiring\b|\bjob\s+(?:opening|opportunity)\b|"
    r"\bopen\s+position\b|\bpositions?\s+available\b|\baccepting\s+applications?\b|"
    r"\bapplications?\s+(?:are\s+)?open\b|\bapply\s+(?:now|here|at|by|before)\b|"
    r"\bwe(?:'re|\s+are)\s+looking\s+for\s+(?:an?|someone|candidates?|developers?|engineers?|consultants?)\b|"
    r"\bseeking\s+(?:an?|someone|candidates?|developers?|engineers?|consultants?)\b|"
    r"\b(?:contract|freelance)\s+(?:role|position|opening|opportunity|project)\b",
    re.IGNORECASE,
)
SEEKER_RE = re.compile(
    r"\[(?:for\s+hire|available)\]|\bfor\s+hire\b|\bhire\s+me\b|"
    r"\bavailable\s+for\s+(?:hire|work|projects?|contracts?)\b|"
    r"\b(?:i(?:'m|\s+am)|we(?:'re|\s+are))\s+(?:currently\s+)?(?:looking|searching)\s+for\s+"
    r"(?:an?\s+)?(?:job|work|opportunit(?:y|ies)|clients?)\b|"
    r"\bseeking\s+(?:an?\s+)?(?:job|work|opportunit(?:y|ies)|clients?)\b",
    re.IGNORECASE,
)

PROFILE_CONFIG: dict[str, dict[str, str | re.Pattern[str]]] = {
    "ai-agent": {
        "query": (
            '("AI agent" OR "agentic AI" OR "LLM engineer" OR "AI automation" '
            'OR "Amazon Connect" OR "conversational AI") '
            '(hiring OR "job opening" OR "contract role" OR "freelance project") '
            '(remote OR "fully remote" OR "remote only" OR "Denton, TX" OR "Denton, Texas")'
        ),
        "role": re.compile(
            r"\b(?:ai\s+agents?|agentic\s+ai|llm|large\s+language\s+model|"
            r"ai\s+automation|generative\s+ai|genai|amazon\s+connect|"
            r"conversational\s+ai|voice\s+(?:ai|bot)|rag|langgraph|langchain)\b",
            re.IGNORECASE,
        ),
        "context": re.compile(
            r"\b(?:fully\s+remote|100%\s+remote|remote[-\s]?only|remote|"
            r"denton\s*,?\s*(?:tx|texas))\b",
            re.IGNORECASE,
        ),
    },
    "nathan": {
        "query": (
            '(paraprofessional OR "instructional aide" OR "substitute teacher" '
            'OR "film teacher" OR "video production teacher" OR "youth program" '
            'OR "victim advocate" OR "nonprofit video") '
            '(hiring OR "job opening" OR "applications open") '
            '(Denton OR DFW OR "North Texas" OR Lewisville OR Frisco OR Dallas OR "Fort Worth")'
        ),
        "role": re.compile(
            r"\b(?:paraprofessional|instructional\s+(?:aide|assistant)|teacher\s+aide|"
            r"substitute\s+teacher|after[-\s]?school|youth\s+(?:program|development|coordinator|advocate)|"
            r"film\s+(?:teacher|instructor)|video\s+production\s+(?:teacher|instructor)|"
            r"media\s+arts\s+teacher|digital\s+media\s+teacher|victim\s+advocate|"
            r"crisis\s+intervention|foster\s+(?:care|youth)|nonprofit|non-profit|"
            r"videographer|video\s+producer|multimedia|communications\s+coordinator)\b",
            re.IGNORECASE,
        ),
        "context": re.compile(
            r"\b(?:denton|dfw|north\s+texas|lewisville|flower\s+mound|frisco|"
            r"carrollton|coppell|plano|grapevine|irving|dallas|fort\s+worth|"
            r"the\s+colony|little\s+elm|aubrey|sanger|argyle|corinth)\b",
            re.IGNORECASE,
        ),
    },
}


def clean_text(value: str) -> str:
    value = unicodedata.normalize("NFKC", value)
    value = html.unescape(value)
    value = re.sub(r"<[^>]+>", " ", value)
    value = html.unescape(value)
    value = "".join(ch for ch in value if unicodedata.category(ch) not in {"Cc", "Cf"})
    value = re.sub(r"\s+submitted by\s+.*$", "", value, flags=re.IGNORECASE)
    return re.sub(r"\s+", " ", value).strip()


def fetch_feed(profile: str) -> bytes:
    query = str(PROFILE_CONFIG[profile]["query"])
    params = urllib.parse.urlencode({"q": query, "sort": "new", "t": "month"})
    request = urllib.request.Request(
        f"{SEARCH_URL}?{params}",
        headers={"Accept": "application/atom+xml", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        if exc.code == 429:
            raise RuntimeError("Reddit RSS rate limited (HTTP 429); not retrying") from exc
        raise RuntimeError(f"Reddit RSS returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Reddit RSS request failed: {exc.reason}") from exc


def parse_feed(raw: bytes, profile: str) -> tuple[int, list[dict[str, str]]]:
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        raise RuntimeError(f"Reddit RSS returned invalid Atom XML: {exc}") from exc

    config = PROFILE_CONFIG[profile]
    role_re = config["role"]
    context_re = config["context"]
    assert isinstance(role_re, re.Pattern)
    assert isinstance(context_re, re.Pattern)

    entries = root.findall("atom:entry", ATOM_NS)
    leads: list[dict[str, str]] = []
    for entry in entries:
        post_id = entry.findtext("atom:id", default="", namespaces=ATOM_NS).strip()
        if not re.fullmatch(r"t3_[a-z0-9]+", post_id):
            continue

        url = next(
            (node.get("href", "") for node in entry.findall("atom:link", ATOM_NS)),
            "",
        )
        if "/comments/" not in url:
            continue

        title = clean_text(entry.findtext("atom:title", default="", namespaces=ATOM_NS))
        body = clean_text(entry.findtext("atom:content", default="", namespaces=ATOM_NS))
        combined = f"{title} {body}"
        if (
            SEEKER_RE.search(combined)
            or not ACTION_RE.search(combined)
            or not role_re.search(combined)
            or not context_re.search(combined)
        ):
            continue

        category = entry.find("atom:category", ATOM_NS)
        subreddit = clean_text(category.get("term", "")) if category is not None else ""
        author = clean_text(
            entry.findtext("atom:author/atom:name", default="", namespaces=ATOM_NS)
        )
        leads.append(
            {
                "id": f"reddit-{post_id.removeprefix('t3_')}",
                "profile": profile,
                "subreddit": subreddit[:80],
                "author": author[:100],
                "title": title[:240],
                "excerpt": body[:500],
                "url": url,
                "updated": entry.findtext(
                    "atom:updated", default="", namespaces=ATOM_NS
                ),
            }
        )

    return len(entries), leads


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=sorted(PROFILE_CONFIG))
    parser.add_argument("atom_file", nargs="?", type=Path)
    args = parser.parse_args()

    try:
        raw = args.atom_file.read_bytes() if args.atom_file else fetch_feed(args.profile)
        entry_count, leads = parse_feed(raw, args.profile)
    except (OSError, RuntimeError) as exc:
        print(f"[reddit-job-leads] {exc}", file=sys.stderr)
        return 1

    for lead in leads:
        print(json.dumps(lead, ensure_ascii=False))
    print(
        f"[reddit-job-leads] profile={args.profile} inspected={entry_count} emitted={len(leads)}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
