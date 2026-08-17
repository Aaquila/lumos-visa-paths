"""The generic pathway graph, read-only, as the backend sees it.

The frontend bundles its own copy of `generic_pathways.json` as a Flutter asset;
this loads the same file from `docs/` so the intake reasoner can only ever
propose a *real* node id. Nothing here mutates the graph — it is a structural
seed, and every number in it still has to be re-verified against its
`source_hint` before it reaches a person (PROJECT_PRD §8.2).
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

#: Repo root is two levels above `app/`. The frontend asset copy is the fallback
#: so a backend-only checkout still starts.
_CANDIDATES = (
    Path(__file__).resolve().parents[2] / "docs" / "generic_pathways.json",
    Path(__file__).resolve().parents[2]
    / "frontend"
    / "assets"
    / "data"
    / "generic_pathways.json",
)


class PathwayNode:
    __slots__ = ("id", "name", "category", "description", "phase", "work_option", "source_hint")

    def __init__(self, raw: dict, phase: int) -> None:
        self.id: str = raw["id"]
        self.name: str = raw["name"]
        self.category: str = raw.get("category", "")
        self.description: str = raw.get("description", "")
        self.phase = phase

        #: Present on nodes that are also *recommendation options* — see the
        #: `node.work_option` schema note in generic_pathways.json and the
        #: ranking in `app/options.py`. Umbrella nodes (O-1, L-1, EB-1) carry
        #: the block with an empty `goals` list so they are never offered on
        #: their own alongside their own sub-categories.
        self.work_option: dict = raw.get("work_option") or {}
        self.source_hint: str = raw.get("source_hint", "")

    @property
    def family(self) -> str:
        return self.id.split(".", 1)[0]


class PathwayGraph:
    def __init__(self, raw: dict) -> None:
        meta = raw.get("meta") or {}
        self.as_of: str = meta.get("as_of", "")
        self.disclaimer: str = meta.get("disclaimer", "")

        #: Cross-cutting guidance that belongs to no single node — parallel
        #: filings, the routes that need no employer, how nationality changes
        #: the option set. Served alongside any broad-goal option set.
        self.strategy_notes: list[dict] = list(meta.get("strategy_notes") or [])

        # `meta.rollout_order` maps id patterns ("student.*", "temp_worker.h1b")
        # to a phase; phase 0 is what the product claims to model today.
        phase_by_pattern: dict[str, int] = {}
        for entry in meta.get("rollout_order") or []:
            for pattern in entry.get("families") or []:
                phase_by_pattern[pattern] = int(entry["phase"])

        def phase_for(node_id: str) -> int:
            if node_id in phase_by_pattern:
                return phase_by_pattern[node_id]
            return phase_by_pattern.get(f"{node_id.split('.', 1)[0]}.*", 3)

        self.nodes: list[PathwayNode] = [
            PathwayNode(n, phase_for(n["id"])) for n in raw.get("nodes") or []
        ]
        self._by_id = {n.id: n for n in self.nodes}
        self.edges: list[dict] = list(raw.get("edges") or [])

    def node(self, node_id: str) -> PathwayNode | None:
        return self._by_id.get(node_id)

    def has(self, node_id: str) -> bool:
        return node_id in self._by_id

    def work_option(self, node_id: str) -> dict:
        """The recommendation metadata for a node, or `{}` if it has none.

        A node without one is a graph position that is not a route somebody can
        choose (LPR, naturalization, the family categories), and it is simply
        never offered as an option.
        """
        node = self._by_id.get(node_id)
        return node.work_option if node else {}

    @property
    def ids(self) -> list[str]:
        return [n.id for n in self.nodes]

    def catalog(self) -> str:
        """The node list as the reasoning model sees it.

        One line per node — id, name, and a trimmed description. This is the
        closed set the model must choose from, so it is sent in full rather than
        retrieved: 43 nodes is small enough to be cheaper than a retrieval step,
        and a complete list is what stops the model inventing a status.
        """
        lines = []
        for n in self.nodes:
            summary = " ".join(n.description.split())
            if len(summary) > 160:
                summary = summary[:157].rstrip() + "…"
            lines.append(f"- {n.id} — {n.name}: {summary}")
        return "\n".join(lines)

    def reachable_from(self, node_id: str) -> set[str]:
        """Every node downstream of [node_id], following non-self edges."""
        seen: set[str] = set()
        queue = [node_id]
        while queue:
            current = queue.pop()
            for edge in self.edges:
                if edge.get("from") != current:
                    continue
                to = edge.get("to")
                if to is None or to == current or to in seen:
                    continue
                seen.add(to)
                queue.append(to)
        return seen


@lru_cache(maxsize=1)
def load_graph() -> PathwayGraph:
    for path in _CANDIDATES:
        if path.exists():
            return PathwayGraph(json.loads(path.read_text(encoding="utf-8")))
    raise FileNotFoundError(
        "generic_pathways.json not found. Looked in: "
        + ", ".join(str(p) for p in _CANDIDATES)
    )
