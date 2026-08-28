"""The management console's snap-in catalog, checked as data.

WHY THIS TEST EXISTS. The console's whole content is a JSON file, which is the right shape for it — a snap-in
is a tree node plus columns plus actions, and writing that as code would mean a component and its own drift per
snap-in. But a JSON catalog with nothing checking it fails IN FRONT OF THE OPERATOR: a mistyped route, a
`source` with no rows path, an action naming a module that does not exist. That is the price of configuration
over code, and this file is how it is paid.

Every assertion here is about the CATALOG, not about a host: no agent is contacted, nothing is polled. What
cannot be checked without a host (does this module exist on that machine) is exactly what the runtime answers
three-valued, with a reason.
"""

from __future__ import annotations

import json

import pytest

from bossman.api.mmc import _catalog, _catalog_path

#: The requirement kinds the server understands. A catalog stating anything else is refused at runtime
#: (see _requirement_verdict), and this list is the same statement made where it can be tested.
KNOWN_REQUIREMENT_KEYS = {"os_family", "module", "feature", "endpoint"}

#: Column render kinds the UI knows. Anything else falls through to plain text, which is a silent
#: near-miss — a size column that renders 34359738368 instead of 32 GB looks like data, not like a typo.
KNOWN_COLUMN_KINDS = {"time", "bytes"}


@pytest.fixture(scope="module")
def catalog() -> dict:
    return _catalog()


def test_the_catalog_is_where_the_code_looks_for_it() -> None:
    """The path resolution differs between the repo and the image, so it is worth one assertion."""
    assert _catalog_path().is_file()
    assert json.loads(_catalog_path().read_text())["version"] >= 1


def test_ids_are_unique_and_addressable(catalog: dict) -> None:
    """A duplicate id is not a cosmetic problem: the node route resolves by id, so the second one would be
    unreachable and its tree entry would silently open the first."""
    ids = [s["id"] for s in catalog["snapins"]]
    assert len(ids) == len(set(ids)), f"duplicate snap-in ids: {sorted({i for i in ids if ids.count(i) > 1})}"

    for snapin in catalog["snapins"]:
        node_ids = [n["id"] for n in snapin["nodes"]]
        assert len(node_ids) == len(set(node_ids)), f"{snapin['id']}: duplicate node ids {node_ids}"
        # A URL segment, so no slashes or spaces — a node id with a slash would split the route.
        for node_id in node_ids:
            assert "/" not in node_id and " " not in node_id, f"{snapin['id']}: bad node id {node_id!r}"


def test_every_snapin_and_node_is_completely_described(catalog: dict) -> None:
    for snapin in catalog["snapins"]:
        for field in ("id", "title", "icon", "description", "requires", "nodes"):
            assert field in snapin, f"snap-in {snapin.get('id')}: missing {field}"
        assert snapin["nodes"], f"snap-in {snapin['id']}: has no nodes, so it can show nothing"
        for node in snapin["nodes"]:
            for field in ("id", "title", "source", "columns", "actions"):
                assert field in node, f"{snapin['id']}/{node.get('id')}: missing {field}"
            assert node["columns"], f"{snapin['id']}/{node['id']}: no columns, so the result pane is blank"


def test_sources_are_one_of_the_two_kinds_and_complete(catalog: dict) -> None:
    for snapin in catalog["snapins"]:
        for node in snapin["nodes"]:
            source = node["source"]
            where = f"{snapin['id']}/{node['id']}"
            assert source.get("kind") in ("tool", "endpoint"), f"{where}: source kind {source.get('kind')!r}"
            # `rows` may be "" (the response IS the array), but it has to be STATED — an absent rows path and
            # an empty one look the same in code and mean different things to whoever wrote the catalog.
            assert "rows" in source, f"{where}: source must state a rows path (\"\" if the response is the list)"
            if source["kind"] == "endpoint":
                assert source["path"].startswith("/api/v1/agents/{agent_id}/"), \
                    f"{where}: an endpoint source must be a per-agent route, got {source['path']!r}"
            else:
                assert source.get("tool"), f"{where}: a tool source must name the module"
                # Parameters are FIXED IN THE CATALOG by design: the node route never forwards request
                # parameters into a module call, so a node cannot be turned into an arbitrary tool call.
                assert isinstance(source.get("params", {}), dict), f"{where}: params must be an object"


def test_column_and_action_shapes(catalog: dict) -> None:
    for snapin in catalog["snapins"]:
        for node in snapin["nodes"]:
            where = f"{snapin['id']}/{node['id']}"
            for column in node["columns"]:
                assert column.get("key"), f"{where}: a column without a key"
                assert column.get("title"), f"{where}: column {column.get('key')} without a title"
                if "kind" in column:
                    assert column["kind"] in KNOWN_COLUMN_KINDS, \
                        f"{where}: column {column['key']} has render kind {column['kind']!r}, which the UI " \
                        f"would ignore — it renders as plain text and nobody would notice"
            for action in node["actions"]:
                assert action.get("id") and action.get("title"), f"{where}: an action without id/title"
                assert action.get("tool"), f"{where}: action {action.get('id')} names no module"
                assert isinstance(action.get("params"), dict), f"{where}: action {action['id']} params"
                if "hide_when" in action:
                    assert set(action["hide_when"]) == {"field", "equals"}, \
                        f"{where}: action {action['id']}: hide_when takes exactly field and equals — there is " \
                        f"deliberately no expression language here"
                # Placeholders must name a column, or the substitution silently sends `undefined` to a host.
                for value in action["params"].values():
                    if isinstance(value, str) and value.startswith("{row."):
                        field = value[5:-1]
                        keys = {c["key"] for c in node["columns"]} | {c.get("fallback") for c in node["columns"]}
                        assert field in keys, \
                            f"{where}: action {action['id']} substitutes {{row.{field}}}, which is not a " \
                            f"column of this node — it would send an empty value to the host"


def test_requirements_use_only_kinds_the_server_understands(catalog: dict) -> None:
    """A requirement the server does not know is refused at runtime (the snap-in reads `unavailable` with that
    reason), which is safe but useless — the point is to catch it here."""
    for snapin in catalog["snapins"]:
        for entry in [snapin, *snapin["nodes"]]:
            for requirement in entry.get("requires") or []:
                assert len(requirement) == 1, \
                    f"{snapin['id']}: a requirement states one condition, got {requirement}"
                key = next(iter(requirement))
                assert key in KNOWN_REQUIREMENT_KEYS, \
                    f"{snapin['id']}: requirement {key!r} is not one of {sorted(KNOWN_REQUIREMENT_KEYS)}"


def test_endpoint_sources_point_at_routes_this_server_serves(catalog: dict) -> None:
    """THE DRIFT TEST, and the one that earns the catalog its keep: every endpoint source is matched against
    the app's own route table with the {agent_id} placeholder in place. A renamed route breaks here instead of
    returning a 404 that a result pane would render as "this node is empty on this host"."""
    from bossman.main import create_app

    # THE OPENAPI SCHEMA, not the route objects. `app.routes` in FastAPI 0.139 holds `_IncludedRouter`
    # wrappers whose real routes sit behind a private attribute, so walking it finds four paths (/docs and
    # friends) and concludes the server serves none of its own API. That mistake was made twice before it was
    # noticed — here, and in a runtime check inside api/mmc.py which refused a route the server was answering
    # at that very moment (the runtime one is gone: there, asking for the route IS the check). The generated
    # schema is FastAPI's own published contract, it is what every client sees, and it does not depend on
    # framework internals staying where they were.
    app = create_app()
    served = set(app.openapi()["paths"])
    assert "/api/v1/agents/{agent_id}/mmc" in served, \
        "the schema read above is wrong: this server's own console route is missing from its OpenAPI paths"

    missing = []
    for snapin in catalog["snapins"]:
        for node in snapin["nodes"]:
            source = node["source"]
            if source["kind"] != "endpoint":
                continue
            path = source["path"].split("?")[0]
            if path not in served:
                missing.append(f"{snapin['id']}/{node['id']} → {path}")

    assert not missing, ("the catalog points at routes this server does not serve:\n  "
                        + "\n  ".join(missing))
