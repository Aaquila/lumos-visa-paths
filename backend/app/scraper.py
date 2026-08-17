"""Daily scraper over the curated USCIS/DOS source list.

Design notes worth keeping in mind if you extend this:

* **Curated, never crawled.** Only URLs in `sources.SOURCES` are fetched, and
  links found on those pages are recorded but never followed.
* **Polite by default.** One request per source, a real User-Agent, a timeout,
  a small delay between sources, and `robots.txt` is honoured.
* **Structure changes are expected.** Government pages get redesigned. Each
  source carries a list of selectors tried in order, and a source that yields
  nothing is reported as a failure rather than silently returning an empty feed.
* **Dates are parsed, never invented.** If no date can be read off the page the
  item simply has none.
"""

from __future__ import annotations

import asyncio
import logging
import re
import urllib.robotparser
from datetime import date, datetime, timedelta, timezone
from urllib.parse import urljoin, urlparse

import httpx
from bs4 import BeautifulSoup

from .models import DocumentMeta, NewsItem, ScrapeReport, utcnow
from .sources import FEDERAL_REGISTER_API, NODE_KEYWORDS, SOURCES, Source

log = logging.getLogger("lumos.scraper")

#: Identify ourselves honestly, but include a browser token: several of the
#: government sites in the allow-list sit behind bot protection that rejects
#: anything without one, and we would rather be identifiable than blocked.
USER_AGENT = (
    "Mozilla/5.0 (compatible; LumosBot/0.1; immigration deadline tracker; "
    "+https://github.com/) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 "
    "Safari/537.36"
)
DEFAULT_HEADERS = {
    "User-Agent": USER_AGENT,
    "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}
REQUEST_TIMEOUT = httpx.Timeout(25.0, connect=10.0)
DELAY_BETWEEN_SOURCES = 1.5

#: How far back the Federal Register query reaches on each run. Comfortably
#: wider than the daily cadence so a few missed days still backfill.
FEDERAL_REGISTER_WINDOW_DAYS = 120
FEDERAL_REGISTER_PER_PAGE = 40

#: Formats seen on USCIS / Study in the States / travel.state.gov listings.
_DATE_FORMATS = (
    "%m/%d/%Y",
    "%B %d, %Y",
    "%b %d, %Y",
    "%Y-%m-%d",
)
_DATE_PATTERN = re.compile(
    r"(\d{1,2}/\d{1,2}/\d{4}"
    r"|[A-Z][a-z]{2,8}\s+\d{1,2},\s+\d{4}"
    r"|\d{4}-\d{2}-\d{2})"
)


def parse_date(text: str) -> datetime | None:
    """Pull the first recognisable date out of `text`, or return None."""
    match = _DATE_PATTERN.search(text or "")
    if not match:
        return None
    raw = match.group(1)
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(raw, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def _iso_date(raw: object) -> date | None:
    """A `YYYY-MM-DD` string from the API, or None. Never a guess."""
    if not isinstance(raw, str) or not raw:
        return None
    try:
        return datetime.strptime(raw[:10], "%Y-%m-%d").date()
    except ValueError:
        return None


def _agency_slugs(raw: object) -> list[str]:
    """Agency slugs out of the API's `agencies` array.

    The array holds objects (`{"slug": ..., "name": ...}`), but the field has
    been served as bare strings before now, so both are accepted rather than
    letting a shape change empty the metadata silently.
    """
    slugs: list[str] = []
    for entry in raw if isinstance(raw, list) else []:
        if isinstance(entry, dict):
            slug = entry.get("slug") or entry.get("raw_name") or entry.get("name")
        else:
            slug = entry
        if isinstance(slug, str) and slug:
            slugs.append(slug)
    return slugs


def _cfr_references(raw: object) -> list[str]:
    """`[{"title": 8, "part": 214}]` → `["8 CFR 214"]`.

    Which CFR part a rule amends is the closest thing the record has to "who
    does this reach": 8 CFR 214 is nonimmigrant classifications, 8 CFR 274a is
    employment authorisation, 8 CFR 204 is immigrant petitions.
    """
    refs: list[str] = []
    for entry in raw if isinstance(raw, list) else []:
        if isinstance(entry, dict):
            title, part = entry.get("title"), entry.get("part")
            if title and part:
                refs.append(f"{title} CFR {part}")
            elif title:
                refs.append(f"{title} CFR")
        elif isinstance(entry, str) and entry:
            refs.append(entry)
    return refs


def match_nodes(source: Source, title: str, summary: str) -> list[str]:
    """Which pathway nodes this item is relevant to.

    A source that declares `related_nodes` is inherently about those statuses.
    Site-wide sources fall back to keyword matching, which is kept deliberately
    narrow — see the note in `sources.NODE_KEYWORDS`.
    """
    if source.related_nodes:
        return list(source.related_nodes)

    haystack = f"{title} {summary}".lower()
    return [
        node
        for node, keywords in NODE_KEYWORDS.items()
        if any(k in haystack for k in keywords)
    ]


class Scraper:
    def __init__(self, sources: tuple[Source, ...] = SOURCES) -> None:
        self.sources = sources
        self._robots: dict[str, urllib.robotparser.RobotFileParser] = {}

    async def _allowed(self, client: httpx.AsyncClient, url: str) -> bool:
        """Honour robots.txt. On any doubt, fetch — these are public policy
        pages we are explicitly told to read — but never against an explicit
        Disallow."""
        parsed = urlparse(url)
        root = f"{parsed.scheme}://{parsed.netloc}"
        parser = self._robots.get(root)
        if parser is None:
            parser = urllib.robotparser.RobotFileParser()
            try:
                response = await client.get(f"{root}/robots.txt")
                if response.status_code == 200:
                    parser.parse(response.text.splitlines())
                else:
                    parser.allow_all = True
            except httpx.HTTPError:
                parser.allow_all = True
            self._robots[root] = parser
        return parser.can_fetch(USER_AGENT, url)

    def _extract(self, source: Source, html: str) -> list[NewsItem]:
        soup = BeautifulSoup(html, "html.parser")

        elements = []
        for selector in source.item_selectors:
            elements = soup.select(selector)
            if elements:
                log.debug("%s matched %s items on %r", source.id, len(elements), selector)
                break

        items: list[NewsItem] = []
        seen_urls: set[str] = set()

        for element in elements[:40]:
            anchor = element.find("a", href=True)
            if anchor is None:
                continue

            title = " ".join(anchor.get_text(" ", strip=True).split())
            if len(title) < 12:
                # Navigation chrome ("More", "Next") rather than an article.
                continue

            url = urljoin(source.url, anchor["href"])
            if url in seen_urls:
                continue
            seen_urls.add(url)

            text = " ".join(element.get_text(" ", strip=True).split())
            summary = text[len(title) :].strip(" -–—|") if text.startswith(title) else text
            summary = summary[:400]

            items.append(
                NewsItem(
                    id=NewsItem.make_id(source.id, url, title),
                    source_id=source.id,
                    source_name=source.name,
                    title=title[:300],
                    url=url,
                    summary=summary,
                    published_at=parse_date(text),
                    matched_nodes=match_nodes(source, title, summary),
                    tags=list(source.tags),
                )
            )

        return items

    async def _scrape_federal_register(
        self, client: httpx.AsyncClient, source: Source
    ) -> list[NewsItem]:
        """Query the Federal Register's public API for one agency.

        The API is documented and unauthenticated, so this is a supported
        integration rather than scraping — no selectors to break.
        """
        since = (
            datetime.now(timezone.utc) - timedelta(days=FEDERAL_REGISTER_WINDOW_DAYS)
        ).date()
        params: list[tuple[str, str]] = [
            ("per_page", str(FEDERAL_REGISTER_PER_PAGE)),
            ("order", "newest"),
            ("conditions[agencies][]", source.fr_agency),
            ("conditions[publication_date][gte]", since.isoformat()),
            *[
                ("fields[]", f)
                for f in (
                    "title",
                    "abstract",
                    "publication_date",
                    "html_url",
                    "type",
                    "document_number",
                    # Structured metadata, asked for explicitly because the API
                    # only returns the fields you name. Relevance scoring reads
                    # these rather than guessing at the prose — a final rule
                    # amending 8 CFR 214 with an effective date is a different
                    # thing from a meeting notice, and only these fields say so.
                    "action",
                    "agencies",
                    "docket_ids",
                    "cfr_references",
                    "effective_on",
                    "comments_close_on",
                )
            ],
        ]
        if source.fr_term:
            params.append(("conditions[term]", source.fr_term))

        response = await client.get(FEDERAL_REGISTER_API, params=params)
        response.raise_for_status()
        payload = response.json()

        items: list[NewsItem] = []
        for result in payload.get("results", []):
            title = (result.get("title") or "").strip()
            url = result.get("html_url") or ""
            if not title or not url:
                continue

            summary = (result.get("abstract") or "").strip()[:400]
            published = None
            if raw_date := result.get("publication_date"):
                try:
                    published = datetime.strptime(raw_date, "%Y-%m-%d").replace(
                        tzinfo=timezone.utc
                    )
                except ValueError:
                    published = None

            doc_type = result.get("type") or ""
            meta = DocumentMeta(
                document_type=doc_type,
                document_number=str(result.get("document_number") or ""),
                action=str(result.get("action") or "")[:300],
                agencies=_agency_slugs(result.get("agencies")),
                docket_ids=[
                    str(d) for d in (result.get("docket_ids") or []) if d
                ],
                cfr_references=_cfr_references(result.get("cfr_references")),
                effective_on=_iso_date(result.get("effective_on")),
                comments_close_on=_iso_date(result.get("comments_close_on")),
            )
            items.append(
                NewsItem(
                    id=NewsItem.make_id(source.id, url, title),
                    source_id=source.id,
                    source_name=source.name,
                    title=title[:300],
                    url=url,
                    summary=summary,
                    published_at=published,
                    matched_nodes=match_nodes(source, title, summary),
                    tags=[*source.tags, doc_type.lower().replace(" ", "-")]
                    if doc_type
                    else list(source.tags),
                    meta=meta,
                )
            )
        return items

    async def scrape_source(
        self, client: httpx.AsyncClient, source: Source
    ) -> list[NewsItem]:
        if source.is_api:
            items = await self._scrape_federal_register(client, source)
            if not items:
                raise ValueError("the API returned no documents in the window")
            return items

        if not await self._allowed(client, source.url):
            raise PermissionError(f"robots.txt disallows {source.url}")

        response = await client.get(source.url)
        response.raise_for_status()
        items = self._extract(source, response.text)
        if not items:
            # An empty result is far more likely to be a changed page structure
            # than genuinely no news, so it is surfaced rather than swallowed.
            raise ValueError(
                "no items matched any known selector — the page structure has "
                "probably changed"
            )
        return items

    async def run(self) -> tuple[list[NewsItem], ScrapeReport]:
        started = utcnow()
        found: list[NewsItem] = []
        ok: list[str] = []
        failed: dict[str, str] = {}

        async with httpx.AsyncClient(
            headers=DEFAULT_HEADERS,
            timeout=REQUEST_TIMEOUT,
            follow_redirects=True,
        ) as client:
            for index, source in enumerate(self.sources):
                if index:
                    await asyncio.sleep(DELAY_BETWEEN_SOURCES)
                try:
                    items = await self.scrape_source(client, source)
                    found.extend(items)
                    ok.append(source.id)
                    log.info("scraped %s: %s items", source.id, len(items))
                except Exception as exc:  # noqa: BLE001 - reported, not raised
                    failed[source.id] = f"{type(exc).__name__}: {exc}"
                    log.warning("scrape failed for %s: %s", source.id, exc)

        return found, ScrapeReport(
            started_at=started,
            finished_at=utcnow(),
            items_found=len(found),
            sources_ok=ok,
            sources_failed=failed,
        )
