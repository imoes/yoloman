# brocade_mlx_module_mem — read-only Starlark check module for the yolo-man agent.
#
# Reproduces the Checkmk "brocade_mlx_module_mem" check which monitors the memory
# of Brocade MLX switch modules via SNMP. The check fetches two SNMP tables:
#
#   .1.3.6.1.4.1.1991.1.1.2.2.1.1  (columns 1=id, 2=descr, 12=state, 24=total, 25=avail)
#   .1.3.6.1.4.1.1991.1.1.2.11.1.1 (OIDEnd + column 5 = cpu utilization, not needed here)
#
# Discovery only yields services for NI-MLX / BR-MLX modules whose state is
# "Running" (state code 10). The memory usage is computed as
#   used = mem_total - mem_avail
# and graded against the supplied warning/critical levels (default 80.0/90.0).

# Brocade MLX module operational states (from the Checkmk source).
_MLX_STATES = {
    "0": ("WARN", "Slot is empty"),
    "2": ("WARN", "Module is going down"),
    "3": ("CRIT", "Rejected due to wrong configuration"),
    "4": ("CRIT", "Hardware is bad"),
    "8": ("WARN", "Configured / Stacking"),
    "9": ("WARN", "In power-up cycle"),
    "10": ("OK", "Running"),
    "11": ("OK", "Blocked for full height card"),
}


def _state_for(state_code):
    """Return (starlark_state, readable) for a numeric state code string."""
    entry = _MLX_STATES.get(state_code)
    if entry != None:
        return entry
    return ("UNKNOWN", "Unhandled state - %s" % state_code)


def _make_item(module_id, module_descr):
    """Build the human-readable item name, mirroring _brocade_mlx_combine_item."""
    descr = module_descr
    if descr == "":
        return module_id
    # Strip a trailing " Module" token from the description, like the source.
    parts = descr.split(" ")
    cleaned = []
    for p in parts:
        if p == "Module":
            continue
        cleaned.append(p)
    return module_id + " " + " ".join(cleaned)


def _fetch_tables(ctx, host, community):
    """Fetch both SNMP tables and return (base_table, cpu_table) as lists.

    base_table rows: [id, descr, state, mem_total, mem_avail]
    cpu_table rows:  [oid_end, cpu_util]  (unused for memory check)
    Returns ([], []) when the host is not a Brocade MLX device.
    """
    # First, verify this is a Brocade MLX device by reading the sysObjectID.
    sys_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_res.rc != 0:
        return [], []
    sys_oid = sys_res.stdout.strip().lower()
    if not sys_oid.startswith(".1.3.6.1.4.1.1991.1."):
        return [], []

    # Fetch the module/memory table. -Oqn gives clean numeric-OID/value lines.
    base_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         ".1.3.6.1.4.1.1991.1.1.2.2.1.1"],
        mutates=False,
    )
    if base_res.rc != 0:
        return [], []

    base = {}
    base_len = len(".1.3.6.1.4.1.1991.1.1.2.2.1.1")
    for line in base_res.stdout.split("\n"):
        if line == "":
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:]
        suffix = full_oid[base_len:]
        cols = suffix.split(".")
        # Expect exactly: <module_id>.<col>  where col in {1,2,12,24,25}
        if len(cols) != 2:
            continue
        mid = cols[0]
        col = cols[1]
        row = base.get(mid)
        if row == None:
            row = {"id": mid, "descr": "", "state": "", "mem_total": "", "mem_avail": ""}
            base[mid] = row
        if col == "1":
            row["id"] = mid
        elif col == "2":
            row["descr"] = value
        elif col == "12":
            row["state"] = value
        elif col == "24":
            row["mem_total"] = value
        elif col == "25":
            row["mem_avail"] = value

    # Fetch the CPU utilization table (column 5 of .1.3.6.1.4.1.1991.1.1.2.11.1.1).
    cpu_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         ".1.3.6.1.4.1.1991.1.1.2.11.1.1.5"],
        mutates=False,
    )
    cpu = []
    if cpu_res.rc == 0:
        base_oid = ".1.3.6.1.4.1.1991.1.1.2.11.1.1.5"
        blen = len(base_oid)
        for line in cpu_res.stdout.split("\n"):
            if line == "":
                continue
            sp = line.find(" ")
            if sp == -1:
                continue
            cpu.append([line[:sp][blen + 1:], line[sp + 1:]])

    # Return base rows sorted by module id for deterministic ordering.
    rows = sorted(base.values(), key=lambda r: r["id"])
    return rows, cpu


def _build_items(rows):
    """Build item -> data mapping from the fetched base rows (mirrors _parse)."""
    parsed = {}
    for r in rows:
        item = _make_item(r["id"], r["descr"])
        state_code = r["state"]
        _st, state_readable = _state_for(state_code)
        # _saveint fallback: non-numeric values become 0.
        mem_total = 0
        if r["mem_total"].lstrip("-").isdigit():
            mem_total = int(r["mem_total"])
        mem_avail = 0
        if r["mem_avail"].lstrip("-").isdigit():
            mem_avail = int(r["mem_avail"])
        parsed[item] = {
            "descr": r["descr"],
            "state_readable": state_readable,
            "mem_total": mem_total,
            "mem_avail": mem_avail,
        }
    return parsed


def _should_discover(data):
    """Decide whether a module is discovered for the memory check."""
    if data["state_readable"] in ["Slot is empty", "Blocked for full height card"]:
        return False
    descr = data["descr"]
    if descr.startswith("NI-MLX") or descr.startswith("BR-MLX"):
        return True
    return False


def _grade_levels(used, total, levels):
    """Grade usage percentage against warn/crit levels.

    Returns one of "OK", "WARN", "CRIT".
    levels is a (warn, crit) tuple of percentages (floats).
    """
    warn = 80.0
    crit = 90.0
    if type(levels) == "list" and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]
    if total <= 0:
        return "OK"
    pct = (used * 100.0) / total
    if pct >= crit:
        return "CRIT"
    if pct >= warn:
        return "WARN"
    return "OK"


def _level_label(state):
    if state == "OK":
        return ""
    if state == "WARN":
        return " (!)"
    if state == "CRIT":
        return " (!!)"
    return ""


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels", [80.0, 90.0])

    # --- Discovery mode ---
    if params.get("_discover"):
        rows, _cpu = _fetch_tables(ctx, host, community)
        if len(rows) == 0:
            return {
                "changed": False,
                "msg": "Brocade MLX device not detected",
                "data": {"discovery": []},
            }
        parsed = _build_items(rows)
        discovery = []
        for item, data in sorted(parsed.items()):
            if _should_discover(data):
                discovery.append({
                    "item": item,
                    "params": {"levels": levels},
                    "metrics": ["mem_used"],
                })
        return {
            "changed": False,
            "msg": "discovered %d memory modules" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- Check mode (single item) ---
    item = params.get("item", "")
    rows, _cpu = _fetch_tables(ctx, host, community)
    if len(rows) == 0:
        return {
            "changed": False,
            "msg": "Brocade MLX device not detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    parsed = _build_items(rows)
    data = parsed.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "Module not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_readable = data["state_readable"]
    if state_readable.lower() != "running":
        return {
            "changed": False,
            "msg": "Module is not running (Current State: %s)" % state_readable,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if data["mem_total"] <= 0 and data["mem_avail"] <= 0:
        # No usable memory figures returned by the device.
        return {
            "changed": False,
            "msg": "No memory data returned by device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used = data["mem_total"] - data["mem_avail"]
    used_pct = (used * 100.0) / data["mem_total"] if data["mem_total"] > 0 else 0.0
    state = _grade_levels(used, data["mem_total"], levels)

    used_mb = used / 1024.0
    total_mb = data["mem_total"] / 1024.0
    msg = "Usage: %f MB (%f%%) of %f MB%s" % (
        used_mb, used_pct, total_mb, _level_label(state),
    )
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "mem_used": used,
                "mem_total": data["mem_total"],
            },
            "details": "Module state: %s" % state_readable,
        },
    }