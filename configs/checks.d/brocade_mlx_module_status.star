# brocade_mlx_module_mem.star — translated from Checkmk's brocade_mlx_module_mem check (SNMP-based)

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

# SNMP base OIDs (mirroring the Checkmk SNMPSection fetch trees)
_MOD_BASE = ".1.3.6.1.4.1.1991.1.1.2.2.1.1"
_CPU_BASE = ".1.3.6.1.4.1.1991.1.1.2.11.1.1"

# Module state table: oid suffix -> readable summary
_MODULE_STATES = {
    "0": (None, "Slot is empty"),
    "2": ("WARN", "Module is going down"),
    "3": ("CRIT", "Rejected due to wrong configuration"),
    "4": ("CRIT", "Hardware is bad"),
    "8": ("WARN", "Configured / Stacking"),
    "9": ("WARN", "In power-up cycle"),
    "10": ("OK", "Running"),
    "11": ("OK", "Blocked for full height card"),
}

def _state_for(s):
    entry = _MODULE_STATES.get(s)
    if entry:
        return entry
    return ("UNKNOWN", "Unhandled state - " + s)

def _combine(module_id, descr):
    if descr == "":
        return module_id
    # strip a trailing " Module" label from the description
    d = descr
    if d.endswith(" Module"):
        d = d[:-len(" Module")]
    elif d == "Module":
        d = ""
    return module_id + " " + d if d else module_id

def _snmp_get(ctx, oid, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _snmp_walk(ctx, oid, community, host):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        idx = line.find(" ")
        if idx < 0:
            continue
        rows.append((line[:idx], line[idx+1:].strip()))
    return rows

def _fetch_modules(ctx, community, host):
    """Fetch the module table (.2.x columns: id, descr, state, mem_total, mem_avail)."""
    walk = _snmp_walk(ctx, _MOD_BASE + ".1", community, host)
    # Column indices per OIDEnd suffix (1=id, 2=descr, 12=state, 24=total, 25=avail)
    col_of = {"1": {}, "2": {}, "12": {}, "24": {}, "25": {}}
    for oid, val in walk:
        suffix = oid[len(_MOD_BASE)+1:]  # e.g. "1.3"
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col, idx = parts[0], parts[1]
        if col in col_of:
            col_of[col][idx] = val
    # Correlate by index
    modules = []
    for idx in col_of["1"]:
        modules.append({
            "id": col_of["1"].get(idx, ""),
            "descr": col_of["2"].get(idx, ""),
            "state": col_of["12"].get(idx, "0"),
            "mem_total": col_of["24"].get(idx, "0"),
            "mem_avail": col_of["25"].get(idx, "0"),
        })
    return modules

def _fetch_cpu(ctx, community, host, module_id):
    """Walk the CPU utilization table for one module id, collecting
    1/5/60/300-second utilization columns by their OIDEnd index suffix."""
    walk = _snmp_walk(ctx, _CPU_BASE + "." + module_id, community, host)
    utils = {"1": None, "5": None, "60": None, "300": None}
    for oid, val in walk:
        # oid like ".1.3...1.1.3.15" — the trailing index suffix after the module id
        suffix = oid[len(_CPU_BASE)+1:]
        parts = suffix.split(".")
        if len(parts) >= 2:
            idx = parts[-1]
            if idx in utils:
                utils[idx] = val
    return utils

def _is_brocade_mlx(ctx, community, host):
    # Verify this is a Brocade/MLX device by reading sysObjectID
    sysoid = _snmp_get(ctx, ".1.3.6.1.2.1.1.2.0", community, host)
    if not sysoid:
        return False
    return sysoid.startswith(".1.3.6.1.4.1.1991.1.")

# ---------- DISCOVERY ----------

def _discover(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if not _is_brocade_mlx(ctx, community, host):
        return {"changed": False, "msg": "not a Brocade MLX device",
                "data": {"discovery": []}}
    modules = _fetch_modules(ctx, community, host)
    out = []
    for m in modules:
        item = _combine(m["id"], m["descr"])
        state_readable = _state_for(m["state"])[1]
        # mirror discovery: skip empty slots
        if state_readable == "Slot is empty":
            continue
        out.append({
            "item": item,
            "params": {"levels": (80.0, 90.0)},
            "metrics": ["mem_used"],
        })
    return {"changed": False, "msg": "discovered %d memory modules" % len(out),
            "data": {"discovery": out}}

# ---------- CHECK (memory) ----------

def _check(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if not _is_brocade_mlx(ctx, community, host):
        return {"changed": False, "msg": "not a Brocade MLX device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Brocade MLX sysObjectID not found"}}
    item = params.get("item", "")
    modules = _fetch_modules(ctx, community, host)

    target = None
    for m in modules:
        if _combine(m["id"], m["descr"]) == item:
            target = m
            break
    if target == None:
        return {"changed": False, "msg": "Module not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_label, state_readable = _state_for(target["state"])
    if state_readable != "Running":
        return {"changed": False,
                "msg": "Module is not running (Current State: " + state_readable + ")",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # parse memory counters (guard against non-numeric values)
    total_s = target["mem_total"]
    avail_s = target["mem_avail"]
    if not total_s or not avail_s:
        return {"changed": False, "msg": "no memory data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not (total_s.lstrip("-").isdigit() and avail_s.lstrip("-").isdigit()):
        return {"changed": False, "msg": "invalid memory counters for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    total = int(total_s)
    avail = int(avail_s)
    used = total - avail

    # threshold handling: params.get("levels", (80,90)) -> (warn, crit)
    levels = params.get("levels")
    warn, crit = 80.0, 90.0
    if levels != None and type(levels) == "tuple" and len(levels) >= 2:
        warn, crit = levels[0], levels[1]

    pct = (used * 100.0 / total) if total > 0 else 0.0
    if pct >= crit:
        st = "CRIT"
    elif pct >= warn:
        st = "WARN"
    else:
        st = "OK"

    return {"changed": False,
            "msg": "Usage: %s used (%d/%d) - %f%%" % (st, used, total, pct),
            "data": {"state": st, "metrics": {"mem_used": used}, "details": ""}}