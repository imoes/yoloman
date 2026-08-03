# ===== Translated Checkmk check: sap_hana_memrate → SAP HANA Memory usage rate =====
# READ-ONLY Starlark module for the yolo-man agent.
#
# Data source: the on-host "global allocation status" / memory-rate data that the
# SAP HANA agent plugin gathers.  The Checkmk plugin parses a `string_table`
# produced by the SAP HANA agent section; here we reproduce the same data by
# querying the HANA instance directly with the `hdbsql` CLI (the same tool the
# agent plugin uses under the hood) and parsing its column output.
#
# Checkmk defaults (from check_default_parameters):
#   levels = ("perc_used", (70.0, 80.0))   # warn 70 %, crit 80 %

def _is_int(s):
    if type(s) == "string":
        return s.isdigit() or (s.startswith("-") and s[1:].isdigit())
    return False

def _to_int(s):
    return int(s) if _is_int(s) else 0

def main(ctx, params):
    # --- parameter handling (Checkmk defaults) ---
    levels = params.get("levels", ("perc_used", (70.0, 80.0)))
    # levels may arrive as a list due to JSON round-tripping
    if type(levels) == "list":
        levels = (levels[0], tuple(levels[1:]))
    warn = 70.0
    crit = 80.0
    if type(levels) == "tuple" and len(levels) >= 2 and type(levels[1]) == "tuple":
        lv = levels[1]
        if len(lv) >= 1 and lv[0] != None:
            warn = float(lv[0])
        if len(lv) >= 2 and lv[1] != None:
            crit = float(lv[1])

    # --- discovery mode ---
    if params.get("_discover"):
        # Establish that hdbsql is actually available; absence => no discovery.
        probe = ctx.run(["hdbsql", "--version"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "hdbsql not available", "data": {"discovery": []}}

        # Discover SAP HANA instances from the running processes / system.
        # Reproduces the agent section's enumeration of sid_instance values.
        ps = ctx.run(["ps", "-eo", "comm=", "args="], mutates=False)
        instances = []
        for line in ps.stdout.splitlines():
            # Each HANA instance appears as e.g. "hdbindex" / "hdbnameserver"
            # with args mentioning the SID.  Collect unique SID tokens.
            parts = line.split()
            for p in parts:
                low = p.lower()
                if low.startswith("hdb") and len(p) >= 3:
                    sid = p[:3].upper()
                    if sid not in instances:
                        instances.append(sid)
        if not instances:
            return {"changed": False, "msg": "no SAP HANA instances found", "data": {"discovery": []}}

        discovery = []
        for sid in instances:
            discovery.append({
                "item": sid,
                "params": {"levels": ("perc_used", (warn, crit))},
                "metrics": ["memory_used", "usage_percent"],
            })
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA instance(s)" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- check mode (single item) ---
    item = params.get("item", "")

    # Verify the product is really present.
    hdbsql_probe = ctx.run(["hdbsql", "--version"], mutates=False)
    if hdbsql_probe.rc != 0:
        return {
            "changed": False,
            "msg": "hdbsql client not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Query the memory rate for this HANA instance.
    # `global_allocation_stat` exposes the memory usage rate in percent.
    # The instance is identified by its SID (item).
    cmd = [
        "hdbsql",
        "-n", item + ":30015",
        "-i", item,
        "-u",
        "SYSTEM",
        "-e",
        "select percent_used, total_size, used_size from sys.m_service_global_allocation",
    ]
    res = ctx.run(cmd, mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "could not query SAP HANA instance " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "no memory rate data for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # The hdbsql columnar output: first line is the header, second line the value.
    fields = lines[1].split()
    if len(fields) < 3:
        return {
            "changed": False,
            "msg": "unexpected hdbsql output for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used = _to_int(fields[0])
    total = _to_int(fields[2])
    # percent_used is the first column if present; otherwise compute it.
    percent = float(fields[0]) if fields[0].isdigit() else 0.0

    # Grade against thresholds (upper-level: warn/crit when >=).
    state = "OK"
    if percent >= crit:
        state = "CRIT"
    elif percent >= warn:
        state = "WARN"

    metrics = {}
    if total > 0:
        metrics["memory_used"] = total - used
        metrics["usage_percent"] = percent
    else:
        metrics["usage_percent"] = percent

    return {
        "changed": False,
        "msg": "Usage: %d%% used of %s" % (int(percent), item),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "used=%d, total=%d" % (used, total),
        },
    }