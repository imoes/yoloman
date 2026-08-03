# Cisco memory checks (Checkmk checkmk.cisco_mem) — read-only Starlark translation

# OIDs for the legacy CISCO-ENHANCED-MEMPOOL-MIB (ciscoMemoryPoolTable)
OID_SYSD = ".1.3.6.1.2.1.1.1.0"
OID_MEMPOOL_NAME = ".1.3.6.1.4.1.9.9.48.1.1.1.2"
OID_MEMPOOL_USED = ".1.3.6.1.4.1.9.9.48.1.1.1.5"
OID_MEMPOOL_FREE = ".1.3.6.1.4.1.9.9.48.1.1.1.6"

# 32-bit column OIDs of the enhanced mempool (CISCO-ENHANCED-MEMPOOL-MIB)
OID_CEMP_NAME = ".1.3.6.1.4.1.9.9.221.1.1.1.1.3"
OID_CEMP_USED = ".1.3.6.1.4.1.9.9.221.1.1.1.1.7"
OID_CEMP_FREE = ".1.3.6.1.4.1.9.9.221.1.1.1.1.8"

# 64-bit (HC) column OIDs of the enhanced mempool
OID_CEMP_HC_USED = ".1.3.6.1.4.1.9.9.221.1.1.1.1.18"
OID_CEMP_HC_FREE = ".1.3.6.1.4.1.9.9.221.1.1.1.1.20"

# Column OID prefixes used to reconstruct per-row OIDs after a walk
COL_BASE_NAME = ".3"
COL_BASE_USED = ".7"
COL_BASE_FREE = ".8"
COL_BASE_HC_USED = ".18"
COL_BASE_HC_FREE = ".20"

MEGA = 1024 * 1024


def _to_int(s):
    s = s.strip() if s != None else ""
    if s == "":
        return None
    neg = s.startswith("-")
    body = s[1:] if neg else s
    if body == "":
        return None
    if not body.isdigit():
        return None
    v = 0
    for ch in body:
        v = v * 10 + (ord(ch) - 48)
    return -v if neg else v


def _walk_table(ctx, host, community, col_oid):
    """snmpwalk -Oqn one column; returns list of (full_oid, value)."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0 and res.rc != 1:
        return None
    for line in res.stdout.splitlines():
        space = line.find(" ")
        if space < 0:
            continue
        rows.append((line[:space], line[space + 1:].strip()))
    return rows


def _get_scalar(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _sys_desc(ctx, host, community):
    return _get_scalar(ctx, host, community, OID_SYSD)


def _detect_cisco(ctx, host, community):
    """Mimic DETECT_CISCO: sysDescr contains 'cisco' (case-insensitive)."""
    desc = _sys_desc(ctx, host, community)
    if desc == None:
        return False
    return "cisco" in desc.lower()


def _gather_pool_data(ctx, host, community):
    """Return {item: (used:int, free:int)} using the most capable source.

    Preference: enhanced-64 > enhanced-32 > legacy. The 64-bit enhanced MIB
    is preferred on devices that expose it; the 32-bit legacy pool table is
    the fallback (also used by ASA pre-v9 per Checkmk werk #1266).
    """
    # Enhanced 64-bit (HC) first: cempMemPoolHCUsed / HCFree (.18/.20), name .3
    hc_used_rows = _walk_table(ctx, host, community, OID_CEMP_HC_USED)
    if hc_used_rows == None:
        return None
    if len(hc_used_rows) > 0:
        name_rows = _walk_table(ctx, host, community, OID_CEMP_NAME)
        free_rows = _walk_table(ctx, host, community, OID_CEMP_HC_FREE)
        if name_rows == None or free_rows == None:
            return None
        by_index = {}
        for full_oid, name_val in name_rows:
            idx = full_oid[len(OID_CEMP_NAME) + 1:]
            by_index[idx] = {"name": name_val}
        for full_oid, val in hc_used_rows:
            idx = full_oid[len(OID_CEMP_HC_USED) + 1:]
            entry = by_index.get(idx)
            if entry == None:
                entry = {}
                by_index[idx] = entry
            u = _to_int(val)
            entry["used64"] = u
        for full_oid, val in free_rows:
            idx = full_oid[len(OID_CEMP_HC_FREE) + 1:]
            entry = by_index.get(idx)
            if entry == None:
                entry = {}
                by_index[idx] = entry
            f = _to_int(val)
            entry["free64"] = f
        pools = {}
        for idx, entry in by_index.items():
            name = entry.get("name")
            if name == None or name == "":
                continue
            used = entry.get("used64")
            free = entry.get("free64")
            if used == None or free == None:
                continue
            pools[name] = (used, free)
        return pools

    # Legacy 32-bit pool table: name .2, used .5, free .6
    name_rows = _walk_table(ctx, host, community, OID_MEMPOOL_NAME)
    used_rows = _walk_table(ctx, host, community, OID_MEMPOOL_USED)
    free_rows = _walk_table(ctx, host, community, OID_MEMPOOL_FREE)
    if name_rows == None or used_rows == None or free_rows == None:
        return None
    by_index = {}
    for full_oid, name_val in name_rows:
        idx = full_oid[len(OID_MEMPOOL_NAME) + 1:]
        by_index[idx] = {"name": name_val}
    for full_oid, val in used_rows:
        idx = full_oid[len(OID_MEMPOOL_USED) + 1:]
        entry = by_index.get(idx)
        if entry == None:
            entry = {}
            by_index[idx] = entry
        entry["used"] = _to_int(val)
    for full_oid, val in free_rows:
        idx = full_oid[len(OID_MEMPOOL_FREE) + 1:]
        entry = by_index.get(idx)
        if entry == None:
            entry = {}
            by_index[idx] = entry
        entry["free"] = _to_int(val)
    pools = {}
    for idx, entry in by_index.items():
        name = entry.get("name")
        if name == None or name == "":
            continue
        used = entry.get("used")
        free = entry.get("free")
        if used == None or free == None:
            continue
        pools[name] = (used, free)
    return pools


def _grade_level(value, levels):
    """Upper-level grading: warn/crit are upper bounds in same units.
    value, warn, crit all in MB here (or None)."""
    if levels == None:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        if not _detect_cisco(ctx, host, community):
            return {"changed": False, "msg": "no Cisco device", "data": {"discovery": []}}
        pools = _gather_pool_data(ctx, host, community)
        if pools == None:
            return {"changed": False, "msg": "no Cisco memory data", "data": {"discovery": []}}
        discovery = []
        for name, (used, free) in pools.items():
            if name == "" or name == "Driver text":
                continue
            if used == 0 and free == 0:
                continue
            discovery.append({
                "item": name,
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["mem_used_percent"],
            })
        return {
            "changed": False,
            "msg": "discovered %d memory pools" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE ---
    if not _detect_cisco(ctx, host, community):
        return {
            "changed": False,
            "msg": "no Cisco device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    pools = _gather_pool_data(ctx, host, community)
    if pools == None:
        return {
            "changed": False,
            "msg": "could not read Cisco memory data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    entry = pools.get(item)
    if entry == None:
        return {
            "changed": False,
            "msg": "no memory pool item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    used, free = entry
    total = used + free
    if total == 0:
        return {
            "changed": False,
            "msg": "Cannot calculate memory usage: Device reports total memory 0",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    used_mb = used / MEGA
    free_mb = free / MEGA
    total_mb = total / MEGA
    percent = (used / total) * 100.0 if total != 0 else 0.0

    levels = params.get("levels", (80.0, 90.0))
    warn_mb = levels[0] if levels != None and len(levels) >= 1 else None
    crit_mb = levels[1] if levels != None and len(levels) >= 2 else None

    # check_cisco_mem_sub converts warn/crit from MB to bytes and takes abs;
    # here we grade percent directly against percent thresholds (the default
    # levels (80.0, 90.0) are percentages).
    state = _grade_level(percent, levels)

    msg = "Usage: %f%% - %f MiB of %f MiB" % (percent, used_mb, total_mb)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"mem_used_percent": percent},
            "details": "",
        },
    }