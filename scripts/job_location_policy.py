#!/usr/bin/env python3
"""Fail-closed location gate for Brandon's AI-agent job search.

Accept only a fully remote role that can be worked from Denton, Texas, or a role
whose listed city is exactly Denton. LinkedIn remote search results require the
public job description to explicitly confirm remote work. TSV input/output keeps
the existing six-column pipeline contract.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import html
from html.parser import HTMLParser
import json
import re
import sys
from typing import Any, Callable, Iterable
from urllib.request import Request, urlopen

REMOTE_BOARD_SOURCES = {
    "workingnomads",
    "remoteok",
    "remotive",
    "himalayas",
    "weworkremotely",
    "wellfound",
}
REMOTE_RE = re.compile(
    r"\b(?:fully\s+remote|100%\s+remote|remote[- ]only|work\s+from\s+(?:home|anywhere)|"
    r"distributed\s+(?:company|team|workforce)|remote)\b",
    re.IGNORECASE,
)
DENTON_RE = re.compile(r"\bDenton\s*,\s*(?:TX|Texas)(?:\s*,\s*United\s+States)?\b", re.IGNORECASE)
CONTRADICTION_RE = re.compile(
    r"\b(?:hybrid|on[- ]?site|in[- ]office|office[- ]based|return[- ]to[- ]office|RTO|"
    r"commut(?:e|able|ing)\s+to\s+(?:the\s+)?[^.;\n]{0,50}\boffice|"
    r"(?:one|two|three|four|five|1|2|3|4|5)\s+days?\s+(?:a|per)\s+week\s+[^.;\n]{0,40}\boffice)\b",
    re.IGNORECASE,
)
AMBIGUOUS_RE = re.compile(
    r"\b(?:remote\s+status\s+(?:is\s+)?(?:unclear|unknown)|unclear\s+(?:if|whether)\s+remote|"
    r"suggests?\s+remote|confirm\s+(?:it(?:'s|\s+is)\s+)?remote|remote\s+not\s+verified)\b",
    re.IGNORECASE,
)
ELIGIBLE_REGION_RE = re.compile(
    r"\b(?:United\s+States|USA|U\.S\.|US[- ]only|North(?:ern)?\s+America|the\s+Americas|"
    r"Worldwide|Anywhere|Global|Texas|TX|Central\s+Time|CST|CDT|EST/CST|US\s+time\s+zones?)\b",
    re.IGNORECASE,
)
INELIGIBLE_REGION_RE = re.compile(
    r"\b(?:Europe|European\s+Union|EU|EMEA|United\s+Kingdom|UK|Canada|India|Australia|APAC|LATAM|"
    r"Latin\s+America|Brazil|Germany|France)\b",
    re.IGNORECASE,
)
SCOPED_INELIGIBLE_RE = re.compile(
    r"(?:\b(?:anywhere|located|based|reside|residents?|applicants?|candidates?|work(?:ing)?|"
    r"hire(?:\s+employees)?|authorization)\b.{0,80}\b(?:Europe|European\s+Union|EU|EMEA|"
    r"United\s+Kingdom|UK|Canada|India|Australia|APAC|LATAM|Latin\s+America|Brazil|Germany|France)\b|"
    r"\b(?:Europe|European\s+Union|EU|EMEA|United\s+Kingdom|UK|Canada|India|Australia|APAC|"
    r"LATAM|Latin\s+America|Brazil|Germany|France)\b.{0,40}\b(?:only|hours?|time\s+zones?|"
    r"candidates?|residents?|work\s+authorization|required|office(?:\s+team)?)\b)",
    re.IGNORECASE,
)
TRAILING_LOCATION_RE = re.compile(r"^(.*?)\s+\[([^\[\]]+)\]\s*$", re.DOTALL)
REMOTE_QUALIFIER_RE = re.compile(
    r"\b(?:location\s*:\s*)?(?:fully\s+|100%\s+)?remote\b\s*(?:[-–—,:]\s*)?"
    r"([^.;|\n\]]{0,80})",
    re.IGNORECASE,
)
SECTION_HEADING_RE = re.compile(
    r"\b(?:Role\s+Summary|Job\s+Summary|Position\s+Summary|Key\s+Responsibilities|"
    r"Responsibilities|About\s+the\s+Role|About\s+Us|Required\s+Skills|Qualifications)\s*:?,?",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class LinkedInDetails:
    location: str
    description: str


@dataclass(frozen=True)
class Decision:
    accepted: bool
    display_title: str
    reason: str


@dataclass(frozen=True)
class RejectedJob:
    job_id: str
    source: str
    reason: str


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def clean(value: object) -> str:
    return re.sub(r"\s+", " ", html.unescape(str(value or ""))).strip()


def strip_html(value: str) -> str:
    parser = _TextExtractor()
    parser.feed(value)
    return clean(" ".join(parser.parts))


def _class_text(page: str, class_name: str) -> str:
    match = re.search(
        rf'<(?P<tag>[a-z0-9]+)[^>]*class="[^"]*{re.escape(class_name)}[^"]*"[^>]*>'
        rf'(?P<body>.*?)</(?P=tag)>',
        page,
        re.IGNORECASE | re.DOTALL,
    )
    return strip_html(match.group("body")) if match else ""


def parse_linkedin_details(payload: bytes) -> LinkedInDetails:
    page = payload.decode("utf-8", "replace")
    return LinkedInDetails(
        location=_class_text(page, "topcard__flavor--bullet"),
        description=_class_text(page, "show-more-less-html__markup"),
    )


def fetch_linkedin_details(url: str, timeout: float = 20.0) -> LinkedInDetails:
    request = Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (compatible; BrandonJobSearch/1.0; personal-use)",
            "Accept": "text/html,application/xhtml+xml",
        },
    )
    with urlopen(request, timeout=timeout) as response:
        payload = response.read(2 * 1024 * 1024 + 1)
    if len(payload) > 2 * 1024 * 1024:
        raise ValueError("LinkedIn detail response exceeded 2 MiB")
    details = parse_linkedin_details(payload)
    if not details.location and not details.description:
        raise ValueError("LinkedIn detail page contained no public location or description")
    return details


def _split_title(title: str) -> tuple[str, str]:
    normalized = clean(title)
    match = TRAILING_LOCATION_RE.match(normalized)
    if not match:
        return normalized, ""
    return clean(match.group(1)), clean(match.group(2))


def _remote_qualifier(text: str) -> str:
    match = REMOTE_QUALIFIER_RE.search(text)
    if not match:
        return ""
    qualifier = clean(match.group(1)).strip(" -–—,:")
    qualifier = SECTION_HEADING_RE.split(qualifier, maxsplit=1)[0].strip(" -–—,:")
    generic_suffixes = ("role", "position", "job", "work", "opportunity", "first")
    if qualifier.casefold() in generic_suffixes:
        return ""
    return qualifier


def _remote_region_allowed(location: str, evidence: str) -> bool:
    location = clean(location)
    qualifier = _remote_qualifier(evidence)
    if SCOPED_INELIGIBLE_RE.search(evidence):
        return False
    if INELIGIBLE_REGION_RE.search(evidence) and not ELIGIBLE_REGION_RE.search(evidence):
        return False

    location_is_generic = not location or location.casefold() == "remote"
    if not location_is_generic:
        if not ELIGIBLE_REGION_RE.search(location):
            return False

    if qualifier:
        if SCOPED_INELIGIBLE_RE.search(qualifier):
            return False
        if ELIGIBLE_REGION_RE.search(qualifier):
            return True
        if INELIGIBLE_REGION_RE.search(qualifier):
            return False
        if re.search(r"\b(?:only|candidates?|residents?|based)\b", qualifier, re.IGNORECASE):
            return False

    return True


def _remote_label(location: str, evidence: str) -> str:
    qualifier = _remote_qualifier(evidence)
    if qualifier:
        return f"Remote — {qualifier}"
    location = clean(location)
    if not location or location.casefold() == "remote":
        return "Remote"
    return f"Remote — {location}"


def evaluate_job(
    source: str,
    title: str,
    *,
    details: LinkedInDetails | None = None,
) -> Decision:
    base_title, listed_location = _split_title(title)
    detail_location = clean(details.location) if details else ""
    description = clean(details.description) if details else ""
    location = detail_location or listed_location
    combined = clean(f"{title} {location} {description}")

    if DENTON_RE.search(location):
        return Decision(True, f"{base_title} [Denton, TX]", "listed in Denton, Texas")
    if source == "linkedin-denton":
        return Decision(False, title, "LinkedIn local result is not listed in Denton, Texas")
    if AMBIGUOUS_RE.search(combined):
        return Decision(False, title, "remote status is explicitly ambiguous or unverified")
    if CONTRADICTION_RE.search(combined):
        return Decision(False, title, "remote evidence has a hybrid/on-site/RTO contradiction")

    if source == "linkedin-remote":
        if details is None:
            return Decision(False, title, "LinkedIn remote candidate detail could not be verified")
        evidence = description
        if not description or not REMOTE_RE.search(description):
            return Decision(False, title, "LinkedIn detail has no explicit remote statement")
        if not _remote_region_allowed(detail_location or listed_location, description):
            return Decision(False, title, "remote restriction is not compatible with working from Denton")
        return Decision(True, f"{base_title} [{_remote_label(location, evidence)}]", "verified remote")

    if source in REMOTE_BOARD_SOURCES:
        if not _remote_region_allowed(listed_location, listed_location):
            return Decision(False, title, "remote board location is not explicitly Denton-compatible")
        return Decision(
            True,
            f"{base_title} [{_remote_label(listed_location, listed_location)}]",
            "remote-only source with compatible location",
        )

    if not REMOTE_RE.search(combined):
        return Decision(False, title, "no explicit remote or Denton location evidence")
    if not _remote_region_allowed(listed_location, combined):
        return Decision(False, title, "remote restriction is not compatible with working from Denton")
    return Decision(
        True,
        f"{base_title} [{_remote_label(listed_location, combined)}]",
        "explicit remote text with compatible location",
    )


def remote_board_candidate_allowed(source: str, location: str, text: str) -> bool:
    """Validate full remote-board source text before its description is discarded."""
    if source not in REMOTE_BOARD_SOURCES:
        return False
    description = strip_html(text)
    combined = clean(f"{location} {description}")
    if AMBIGUOUS_RE.search(combined) or CONTRADICTION_RE.search(combined):
        return False
    return _remote_region_allowed(location, description)


def _parse_tsv(line: str) -> tuple[str, str, str, str, str, str] | None:
    fields = line.rstrip("\n").split("\t")
    if len(fields) != 6:
        return None
    return tuple(fields)  # type: ignore[return-value]


def _load_linkedin_details(
    rows: list[tuple[str, str, str, str, str, str]],
    fetcher: Callable[[str], LinkedInDetails],
) -> dict[str, LinkedInDetails]:
    urls = sorted({row[4] for row in rows if row[1] == "linkedin-remote" and row[4]})
    if not urls:
        return {}
    details: dict[str, LinkedInDetails] = {}
    with ThreadPoolExecutor(max_workers=min(6, len(urls))) as executor:
        futures = {executor.submit(fetcher, url): url for url in urls}
        for future in as_completed(futures):
            url = futures[future]
            try:
                details[url] = future.result()
            except Exception as error:
                print(
                    f"[job-location-policy] LinkedIn detail unavailable: {url} "
                    f"({type(error).__name__}: {error})",
                    file=sys.stderr,
                )
    return details


def filter_tsv(
    lines: Iterable[str],
    *,
    linkedin_details: dict[str, LinkedInDetails] | None = None,
    fetcher: Callable[[str], LinkedInDetails] = fetch_linkedin_details,
) -> tuple[list[str], list[RejectedJob]]:
    rows: list[tuple[str, str, str, str, str, str]] = []
    rejected: list[RejectedJob] = []
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        row = _parse_tsv(line)
        if row is None:
            rejected.append(RejectedJob(f"line-{line_number}", "unknown", "malformed TSV row"))
            continue
        rows.append(row)

    details_by_url = (
        dict(linkedin_details)
        if linkedin_details is not None
        else _load_linkedin_details(rows, fetcher)
    )
    accepted: list[str] = []
    for job_id, source, company, title, url, salary in rows:
        decision = evaluate_job(source, title, details=details_by_url.get(url))
        if not decision.accepted:
            rejected.append(RejectedJob(job_id, source, decision.reason))
            continue
        normalized_source = "linkedin" if source.startswith("linkedin-") else source
        accepted.append(
            "\t".join((job_id, normalized_source, company, decision.display_title, url, salary))
        )
    return accepted, rejected


def _job_score_candidates(raw: str) -> list[Any]:
    """Extract score-like JSON values without ignoring malformed score objects."""
    candidates: list[Any] = []
    decoder = json.JSONDecoder()
    cursor = 0
    score_keys = {"idx", "score", "reason"}
    while cursor < len(raw):
        starts = [index for marker in "[{" if (index := raw.find(marker, cursor)) >= 0]
        if not starts:
            break
        start = min(starts)
        try:
            value, end = decoder.raw_decode(raw, start)
        except ValueError:
            cursor = start + 1
            continue
        if isinstance(value, dict) and score_keys.intersection(value):
            candidates.append(value)
        elif isinstance(value, list) and any(
            not isinstance(item, dict) or score_keys.intersection(item) for item in value
        ):
            candidates.extend(value)
        cursor = end
    return candidates


def validate_job_scores(raw: str, expected_count: int) -> list[dict[str, Any]]:
    """Require one exact, sequential score object for every model input row."""
    if expected_count < 1:
        raise ValueError("expected score count must be positive")
    candidates = _job_score_candidates(raw)
    if len(candidates) != expected_count:
        raise ValueError(f"score count {len(candidates)} != expected {expected_count}")

    required_keys = {"idx", "score", "reason"}
    validated: list[dict[str, Any]] = []
    for position, item in enumerate(candidates, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"score object {position} is not an object")
        if set(item) != required_keys:
            missing = sorted(required_keys - set(item))
            extra = sorted(set(item) - required_keys)
            raise ValueError(
                f"score object {position} has invalid schema "
                f"(missing={missing}, extra={extra})"
            )
        if type(item["idx"]) is not int or item["idx"] != position:
            raise ValueError(
                f"score object {position} has invalid index {item['idx']!r}; "
                f"expected sequential index {position}"
            )
        if type(item["score"]) is not int or not 1 <= item["score"] <= 5:
            raise ValueError(f"score object {position} has invalid score {item['score']!r}")
        if not isinstance(item["reason"], str) or not item["reason"].strip():
            raise ValueError(f"score object {position} has invalid reason")
        validated.append(
            {"idx": item["idx"], "score": item["score"], "reason": item["reason"].strip()}
        )
    return validated


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default="-", help="TSV/raw model-output path, or - for stdin")
    parser.add_argument(
        "--validate-scores",
        action="store_true",
        help="validate model JSON score objects instead of filtering job TSV",
    )
    parser.add_argument("--expected-count", type=int)
    args = parser.parse_args()
    source = sys.stdin if args.input == "-" else open(args.input, encoding="utf-8")
    try:
        if args.validate_scores:
            if args.expected_count is None:
                parser.error("--validate-scores requires --expected-count")
            try:
                scores = validate_job_scores(source.read(), args.expected_count)
            except ValueError as error:
                print(f"[job-score-validator] {error}", file=sys.stderr)
                return 1
            for score in scores:
                print(json.dumps(score, ensure_ascii=False, separators=(",", ":")))
            return 0

        accepted, rejected = filter_tsv(source)
    finally:
        if source is not sys.stdin:
            source.close()
    for row in accepted:
        print(row)
    for item in rejected:
        print(
            f"[job-location-policy] reject {item.job_id} ({item.source}): {item.reason}",
            file=sys.stderr,
        )
    print(
        f"[job-location-policy] accepted={len(accepted)} rejected={len(rejected)}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
