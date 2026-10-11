#!/usr/bin/env python3
"""Fetch AI-focused remote jobs from public board feeds for personal use."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime
from email.utils import parsedate_to_datetime
from hashlib import sha256
from html import unescape
from html.parser import HTMLParser
import json
import re
import sys
from typing import Callable
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

from job_location_policy import remote_board_candidate_allowed

USER_AGENT = "Mozilla/5.0 (compatible; BrandonJobSearch/1.0; personal-use)"
MAX_RESPONSE_BYTES = 5 * 1024 * 1024
SOURCE_URLS = {
    "workingnomads": "https://www.workingnomads.com/api/exposed_jobs/",
    "remoteok": "https://remoteok.com/api",
    "remotive": "https://remotive.com/api/remote-jobs?search=ai",
    "himalayas": "https://himalayas.app/jobs/rss",
    "weworkremotely": "https://weworkremotely.com/categories/remote-programming-jobs.rss",
    "wellfound": "https://wellfound.com/role/r/ai-engineer",
}
SOURCE_PREFIXES = {
    "workingnomads": "wn",
    "remoteok": "rok",
    "remotive": "rem",
    "himalayas": "him",
    "weworkremotely": "wwr",
    "wellfound": "wf",
}
DIRECT_TITLE_RE = re.compile(
    r"\b(?:AI|artificial intelligence|machine learning|ML|LLM|large language model|"
    r"generative AI|genAI|agentic|prompt engineer|MLOps|NLP|applied scientist|data scientist|"
    r"conversational AI|voice (?:AI|agent|engineer|architect|bot)|speech (?:engineer|scientist)|"
    r"Amazon Connect|Connect and Lex|contact cent(?:er|re)|CCaaS|"
    r"delivery consultant|professional services consultant|contact center consultant|"
    r"automation (?:engineer|architect|developer)|intelligent automation)\b",
    re.IGNORECASE,
)
SENIORITY_RE = re.compile(r"\b(?:senior|sr\.?|staff|principal|lead|architect|founding)\b", re.IGNORECASE)
PREFERRED_LOCATION_RE = re.compile(
    r"\b(?:United States|USA|U\.S\.|US only|North America|Americas?|Worldwide|Anywhere|Global|Remote)\b",
    re.IGNORECASE,
)


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def strip_html(value: object) -> str:
    parser = _TextExtractor()
    try:
        parser.feed(str(value or ""))
        return clean(" ".join(parser.parts))
    except Exception:
        return clean(value)


def clean(value: object) -> str:
    text = unescape(str(value or ""))
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def parse_timestamp(value: object) -> float:
    text = clean(value)
    if not text:
        return 0.0
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        try:
            return parsedate_to_datetime(text).timestamp()
        except (TypeError, ValueError, OverflowError):
            return 0.0


def stable_id(source: str, explicit_id: object, url: str) -> str:
    token = clean(explicit_id)
    if not token:
        token = sha256(url.encode("utf-8", "replace")).hexdigest()[:14]
    token = re.sub(r"[^A-Za-z0-9_-]+", "-", token).strip("-")
    return f"{SOURCE_PREFIXES[source]}-{token}"


def relevance_score(title: str, _metadata: str, _description: str) -> int:
    if re.search(r"\b(?:QA|test) automation engineer\b", title, re.IGNORECASE):
        return 0
    if not DIRECT_TITLE_RE.search(title):
        return 0
    score = 4
    if SENIORITY_RE.search(title):
        score += 1
    return score


def location_rank(location: str) -> int:
    return 1 if not location or PREFERRED_LOCATION_RE.search(location) else 0


def explicit_salary_range(minimum: object, maximum: object) -> str:
    try:
        low = int(float(minimum or 0))
        high = int(float(maximum or 0))
    except (TypeError, ValueError):
        return ""
    if low <= 0 and high <= 0:
        return ""
    if low > 0 and high > 0:
        return f"${low:,}-${high:,}"
    value = low or high
    return f"${value:,}"


@dataclass(frozen=True)
class Job:
    source: str
    job_id: str
    company: str
    title: str
    url: str
    location: str
    salary: str
    published_at: float
    relevance: int

    def tsv(self) -> str:
        display_title = self.title
        if self.location:
            display_title = f"{display_title} [{self.location}]"
        fields = (self.job_id, self.source, self.company or "-", display_title, self.url, self.salary)
        return "\t".join(clean(field) for field in fields)


def make_job(
    source: str,
    explicit_id: object,
    company: object,
    title: object,
    url: object,
    location: object = "",
    salary: object = "",
    published_at: object = "",
    metadata: object = "",
    description: object = "",
) -> Job | None:
    job_title = clean(title)
    job_url = clean(url)
    job_company = clean(company)
    job_location = clean(location)
    if not job_title or not re.match(r"^https?://", job_url):
        return None
    description_text = strip_html(description)
    evidence_text = f"{clean(metadata)} {description_text}"
    if not remote_board_candidate_allowed(source, job_location, evidence_text):
        return None
    score = relevance_score(job_title, clean(metadata), description_text[:3000])
    if not score:
        return None
    return Job(
        source=source,
        job_id=stable_id(source, explicit_id, job_url),
        company=job_company,
        title=job_title,
        url=job_url,
        location=job_location,
        salary=clean(salary),
        published_at=parse_timestamp(published_at),
        relevance=score,
    )


def fetch(url: str) -> bytes:
    request = Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/json, application/rss+xml, application/xml, text/html;q=0.9, */*;q=0.8",
        },
    )
    with urlopen(request, timeout=25) as response:
        payload = response.read(MAX_RESPONSE_BYTES + 1)
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ValueError(f"response exceeded {MAX_RESPONSE_BYTES} bytes")
    return payload


def parse_workingnomads(payload: bytes) -> list[Job]:
    rows = json.loads(payload)
    jobs: list[Job] = []
    for row in rows:
        url = clean(row.get("url"))
        match = re.search(r"/job/go/(\d+)", url)
        job = make_job(
            "workingnomads",
            match.group(1) if match else "",
            row.get("company_name"),
            row.get("title"),
            url,
            row.get("location"),
            "",
            row.get("pub_date"),
            f"{row.get('category_name', '')} {row.get('tags', '')}",
            row.get("description"),
        )
        if job:
            jobs.append(job)
    return jobs


def parse_remoteok(payload: bytes) -> list[Job]:
    rows = json.loads(payload)
    jobs: list[Job] = []
    for row in rows:
        if not isinstance(row, dict) or not row.get("id"):
            continue
        job = make_job(
            "remoteok",
            row.get("id"),
            row.get("company"),
            row.get("position"),
            row.get("url"),
            row.get("location"),
            explicit_salary_range(row.get("salary_min"), row.get("salary_max")),
            row.get("date") or row.get("epoch"),
            " ".join(str(tag) for tag in row.get("tags") or []),
            row.get("description"),
        )
        if job:
            jobs.append(job)
    return jobs


def parse_remotive(payload: bytes) -> list[Job]:
    rows = json.loads(payload).get("jobs", [])
    jobs: list[Job] = []
    for row in rows:
        job = make_job(
            "remotive",
            row.get("id"),
            row.get("company_name"),
            row.get("title"),
            row.get("url"),
            row.get("candidate_required_location"),
            row.get("salary"),
            row.get("publication_date"),
            f"{row.get('category', '')} {' '.join(str(tag) for tag in row.get('tags') or [])}",
            row.get("description"),
        )
        if job:
            jobs.append(job)
    return jobs


def parse_himalayas(payload: bytes) -> list[Job]:
    root = ET.fromstring(payload)
    namespace = "{https://himalayas.app/ns/jobs}"
    jobs: list[Job] = []
    for item in root.findall("./channel/item"):
        url = item.findtext("link") or item.findtext("guid") or ""
        locations = [clean(node.text) for node in item.findall(f"{namespace}locationRestriction") if clean(node.text)]
        categories = " ".join(clean(node.text) for node in item.findall("category"))
        job = make_job(
            "himalayas",
            "",
            item.findtext(f"{namespace}companyName"),
            item.findtext("title"),
            url,
            ", ".join(locations[:6]),
            "",
            item.findtext("pubDate"),
            categories,
            item.findtext("description"),
        )
        if job:
            jobs.append(job)
    return jobs


def parse_weworkremotely(payload: bytes) -> list[Job]:
    root = ET.fromstring(payload)
    jobs: list[Job] = []
    for item in root.findall("./channel/item"):
        raw_title = clean(item.findtext("title"))
        company, separator, title = raw_title.partition(":")
        if not separator:
            company, title = "", raw_title
        job = make_job(
            "weworkremotely",
            "",
            company,
            title,
            item.findtext("link") or item.findtext("guid"),
            item.findtext("region"),
            "",
            item.findtext("pubDate"),
            item.findtext("category"),
            item.findtext("description"),
        )
        if job:
            jobs.append(job)
    return jobs


def parse_wellfound(payload: bytes) -> list[Job]:
    page = payload.decode("utf-8", "replace")
    match = re.search(r'<script[^>]+id="__NEXT_DATA__"[^>]*>(.*?)</script>', page, re.DOTALL)
    if not match:
        raise ValueError("missing __NEXT_DATA__")
    next_data = json.loads(match.group(1))
    data = next_data["props"]["pageProps"]["apolloState"]["data"]
    talent = data["ROOT_QUERY"]["talent"]
    results = next(
        value
        for key, value in talent.items()
        if key.startswith("seoLandingPageJobSearchResults") and isinstance(value, dict)
    )
    jobs: list[Job] = []
    for startup_reference in results.get("startups", []):
        startup = data.get(startup_reference.get("__ref"), {})
        company = startup.get("name", "")
        for job_reference in startup.get("highlightedJobListings", []):
            row = data.get(job_reference.get("__ref"), {})
            if not row.get("remote"):
                continue
            accepted = [clean(value) for value in row.get("acceptedRemoteLocationNames") or [] if clean(value)]
            fallback = [clean(value) for value in row.get("locationNames") or [] if clean(value)]
            location = ", ".join((accepted or fallback or ["Remote"])[:6])
            job_id = row.get("id")
            slug = clean(row.get("slug"))
            url = f"https://wellfound.com/jobs/{job_id}-{slug}"
            job = make_job(
                "wellfound",
                job_id,
                company,
                row.get("title"),
                url,
                location,
                row.get("compensation"),
                row.get("liveStartAt"),
                row.get("primaryRoleTitle"),
                row.get("description"),
            )
            if job:
                jobs.append(job)
    return jobs


PARSERS: dict[str, Callable[[bytes], list[Job]]] = {
    "workingnomads": parse_workingnomads,
    "remoteok": parse_remoteok,
    "remotive": parse_remotive,
    "himalayas": parse_himalayas,
    "weworkremotely": parse_weworkremotely,
    "wellfound": parse_wellfound,
}


def ordered_unique(jobs: list[Job], limit: int) -> list[Job]:
    ordered = sorted(
        jobs,
        key=lambda job: (
            -job.relevance,
            -location_rank(job.location),
            -job.published_at,
            job.company.casefold(),
            job.title.casefold(),
            job.job_id,
        ),
    )
    seen_ids: set[str] = set()
    seen_roles: set[tuple[str, str]] = set()
    selected: list[Job] = []
    for job in ordered:
        role_key = (job.company.casefold(), job.title.casefold())
        if job.job_id in seen_ids or role_key in seen_roles:
            continue
        seen_ids.add(job.job_id)
        seen_roles.add(role_key)
        selected.append(job)
        if len(selected) >= limit:
            break
    return selected


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit-per-source", type=int, default=10)
    parser.add_argument("--source", action="append", choices=tuple(SOURCE_URLS))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.limit_per_source < 1 or args.limit_per_source > 50:
        raise SystemExit("--limit-per-source must be between 1 and 50")
    selected_sources = args.source or list(SOURCE_URLS)
    payloads: dict[str, bytes] = {}
    errors: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=len(selected_sources)) as executor:
        futures = {executor.submit(fetch, SOURCE_URLS[source]): source for source in selected_sources}
        for future in as_completed(futures):
            source = futures[future]
            try:
                payloads[source] = future.result()
            except Exception as error:
                errors[source] = f"fetch failed: {type(error).__name__}: {error}"

    emitted: list[Job] = []
    successful_sources = 0
    for source in selected_sources:
        if source in errors:
            print(f"[remote-job-boards] {source}: {errors[source]}", file=sys.stderr)
            continue
        try:
            parsed = PARSERS[source](payloads[source])
            selected = ordered_unique(parsed, args.limit_per_source)
        except Exception as error:
            print(
                f"[remote-job-boards] {source}: parse failed: {type(error).__name__}: {error}",
                file=sys.stderr,
            )
            continue
        successful_sources += 1
        emitted.extend(selected)
        print(
            f"[remote-job-boards] {source}: matched={len(parsed)} emitted={len(selected)}",
            file=sys.stderr,
        )

    for job in emitted:
        print(job.tsv())
    if successful_sources == 0:
        print("[remote-job-boards] all sources failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
