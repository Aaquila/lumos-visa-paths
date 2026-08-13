"""The curated allow-list of sources the scraper is permitted to read.

Curated, not crawled. Every entry is an official US government source, and the
scraper never follows links off them — which keeps the job polite, predictable,
and defensible if anyone asks what we hit and why (PROJECT_PRD §5, "curated
allow-list of pages, not open-ended crawling").

Two kinds of source, in deliberate priority order:

* **Federal Register API** (`SourceKind.FEDERAL_REGISTER`) — the government's
  own machine-readable feed of rules, proposed rules and notices, including
  everything USCIS, DHS, State and DOL publish. This is the primary source: it
  is an official API rather than a page we parse, it is stable, and it is the
  authoritative record of a policy change rather than a summary of one.

* **HTML pages** (`SourceKind.HTML`) — the USCIS newsroom and friends. These
  carry operational updates that never reach the Federal Register (processing
  alerts, cap-season announcements). They are also the fragile half: several of
  these sites sit behind bot protection and return 403 to anything that is not
  a browser, from some networks and not others. The scraper reports each source
  independently for exactly this reason — a blocked USCIS page must not empty
  the whole feed.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class SourceKind(str, Enum):
    FEDERAL_REGISTER = "federal_register"
    HTML = "html"


@dataclass(frozen=True)
class Source:
    """One source the scraper watches."""

    id: str
    name: str
    url: str
    kind: SourceKind = SourceKind.HTML

    #: Pathway node ids this source is inherently about. An item from a source
    #: with `related_nodes` inherits them; anything else is keyword-matched.
    related_nodes: tuple[str, ...] = ()

    #: Federal Register only: the agency slug and optional search term.
    fr_agency: str = ""
    fr_term: str = ""

    #: HTML only: CSS selectors tried in order. The first that yields results
    #: wins, so a site redesign degrades to the next selector instead of
    #: returning nothing.
    item_selectors: tuple[str, ...] = (
        "article",
        ".views-row",
        ".news-item",
        "li.usa-collection__item",
        "main li",
    )

    tags: tuple[str, ...] = field(default=())

    @property
    def is_api(self) -> bool:
        return self.kind is SourceKind.FEDERAL_REGISTER


FEDERAL_REGISTER_API = "https://www.federalregister.gov/api/v1/documents.json"

SOURCES: tuple[Source, ...] = (
    # ── Federal Register (official API) ───────────────────────────────────────
    Source(
        id="fr_uscis",
        name="Federal Register — USCIS rules and notices",
        url="https://www.federalregister.gov/agencies/u-s-citizenship-and-immigration-services",
        kind=SourceKind.FEDERAL_REGISTER,
        fr_agency="u-s-citizenship-and-immigration-services",
        tags=("federal-register", "uscis"),
    ),
    Source(
        id="fr_dhs_immigration",
        name="Federal Register — DHS immigration items",
        url="https://www.federalregister.gov/agencies/homeland-security-department",
        kind=SourceKind.FEDERAL_REGISTER,
        fr_agency="homeland-security-department",
        fr_term="immigration",
        tags=("federal-register", "dhs"),
    ),
    Source(
        id="fr_state_visa",
        name="Federal Register — State Department visa items",
        url="https://www.federalregister.gov/agencies/state-department",
        kind=SourceKind.FEDERAL_REGISTER,
        fr_agency="state-department",
        fr_term="visa",
        tags=("federal-register", "state", "visa-bulletin"),
    ),
    Source(
        id="fr_dol_labor_cert",
        name="Federal Register — DOL labor certification (PERM, LCA)",
        url="https://www.federalregister.gov/agencies/employment-and-training-administration",
        kind=SourceKind.FEDERAL_REGISTER,
        fr_agency="employment-and-training-administration",
        fr_term="labor certification",
        related_nodes=(
            "employment_gc.eb2",
            "employment_gc.eb3",
            "temp_worker.h1b",
        ),
        tags=("federal-register", "dol", "perm"),
    ),
    # ── Curated HTML pages ────────────────────────────────────────────────────
    Source(
        id="uscis_newsroom",
        name="USCIS Newsroom — all news releases",
        url="https://www.uscis.gov/newsroom/all-news",
        tags=("uscis", "general"),
    ),
    Source(
        id="uscis_alerts",
        name="USCIS Newsroom — alerts",
        url="https://www.uscis.gov/newsroom/alerts",
        tags=("uscis", "alert"),
    ),
    Source(
        id="uscis_h1b",
        name="USCIS — H-1B electronic registration process",
        url="https://www.uscis.gov/working-in-the-united-states/temporary-workers/h-1b-specialty-occupations/h-1b-electronic-registration-process",
        related_nodes=("temp_worker.h1b", "student.cap_gap"),
        tags=("uscis", "h1b", "cap"),
    ),
    Source(
        id="study_in_the_states",
        name="Study in the States — blog (SEVP)",
        url="https://studyinthestates.dhs.gov/blog",
        related_nodes=(
            "student.f1",
            "student.cpt",
            "student.opt_postcompletion",
            "student.stem_opt",
            "student.cap_gap",
        ),
        tags=("f1", "sevis"),
    ),
    Source(
        id="visa_bulletin",
        name="State Department — Visa Bulletin",
        url="https://travel.state.gov/content/travel/en/legal/visa-law0/visa-bulletin.html",
        related_nodes=(
            "employment_gc.eb1",
            "employment_gc.eb2",
            "employment_gc.eb2_niw",
            "employment_gc.eb3",
            "employment_gc.eb5",
            "family_gc.f1",
            "family_gc.f2a",
            "family_gc.f2b",
            "family_gc.f3",
            "family_gc.f4",
        ),
        tags=("visa-bulletin", "priority-date"),
    ),
)

SOURCES_BY_ID = {s.id: s for s in SOURCES}


#: Keywords used to match an item to a pathway node when the source itself is
#: not status-specific. Deliberately narrow: a false match that moves someone's
#: deadline is worse than a missed alert they can still find by browsing.
NODE_KEYWORDS: dict[str, tuple[str, ...]] = {
    "student.f1": ("f-1", "f1 student", "sevis", "sevp", "i-20", "student visa"),
    "student.cpt": ("curricular practical training", "cpt"),
    "student.opt_postcompletion": (
        "optional practical training",
        "opt ",
        "i-765",
        "employment authorization document",
    ),
    "student.stem_opt": ("stem opt", "i-983", "e-verify"),
    "student.cap_gap": ("cap-gap", "cap gap"),
    "temp_worker.h1b": ("h-1b", "h1b", "cap season", "i-129", "lca", "specialty occupation"),
    "temp_worker.h2a": ("h-2a", "agricultural worker"),
    "temp_worker.h2b": ("h-2b", "non-agricultural"),
    "exchange.j1": ("j-1", "exchange visitor", "ds-2019", "212(e)"),
    "extraordinary.o1": ("o-1", "extraordinary ability"),
    "intracompany.l1": ("l-1", "intracompany"),
    "employment_gc.eb1": ("eb-1", "eb1", "priority worker"),
    "employment_gc.eb2": ("eb-2", "eb2", "perm", "labor certification"),
    "employment_gc.eb2_niw": ("national interest waiver", "niw", "dhanasar"),
    "employment_gc.eb3": ("eb-3", "eb3", "skilled worker"),
    "employment_gc.eb5": ("eb-5", "eb5", "regional center", "i-526"),
    "family_gc.marriage_aos": (
        "i-130",
        "i-485",
        "adjustment of status",
        "i-751",
        "marriage-based",
    ),
    "family_gc.immediate_relative": ("immediate relative",),
    "post_lpr.lpr": ("green card", "permanent resident", "i-90"),
    "post_lpr.naturalization": ("n-400", "naturalization", "citizenship"),
    "humanitarian.tps": ("temporary protected status", "tps"),
    "humanitarian.asylum": ("asylum", "i-589"),
    "humanitarian.refugee": ("refugee",),
    "diversity.dv": ("diversity visa", "dv lottery"),
}
