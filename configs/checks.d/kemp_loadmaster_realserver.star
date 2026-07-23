# ===== Starlark check module: kemp_loadmaster_realserver =====
# Note: NO try/except, NO is/is not, NO f-strings — use %, .format(), or string concat

# SNMP OID constants
_BASE_OID = ".1.3.6.1.4.1.12196.13.2.1"
_OID_RSVIDX = "1"
_OID_RSIP = "2"
_OID_RSSSTATE = "8"

# State mapping: SNMP state string -> (StateString, Description)
_RS_STATE_MAP = {
    "1": ("OK", "in service"),
    "2": ("CRIT", "out of service"),
    "3": ("CRIT", "failed"),
    "4": ("CRIT", "disabled"),
}

def _snmpwalk(ctx, community, host, base_oid, oid_suffix):
    # Returns list of (oid_suffix_value, value) pairs for given base + suffix
    # Command: snmpwalk -v2c -c community -On host base_oid.oid_suffix
    oid = base_oid + "." + oid_suffix
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    if res.rc != 0:
        return []
    lines = res.stdout.splitlines()
    out = []
    for line in lines:
        # Format: OID = STRING: "value"  or OID = INTEGER: value
        # We need the value part after the last space and colon
        parts = line.strip().split()
        if len(parts) < 3:
            continue
        # Remove trailing quotes if present
        val = parts[-1].strip('"')
        # Extract just the value, strip quotes
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        out.append(val)
    return out

def _parse_realserver_section(ctx, community, host):
    # Fetch all three columns and zip into tuples (id_vs, ip_address, state)
    ids = _snmpwalk(ctx, community, host, _BASE_OID, _OID_RSVIDX)
    ips = _snmpwalk(ctx, community, host, _BASE_OID, _OID_RSIP)
    states = _snmpwalk(ctx, community, host, _BASE_OID, _OID_RSSSTATE)
    # Ensure same length
    n = len(ids)
    if len(ips) < n:
        n = len(ips)
    if len(states) < n:
        n = len(states)
    rows = []
    i = 0
    while i < n:
        rows.append((ids[i].strip(), ips[i].strip(), states[i].strip()))
        i = i + 1
    return rows

def _discover(ctx, community, host):
    rows = _parse_realserver_section(ctx, community, host)
    # Group by IP address
    by_ip = {}
    i = 0
    while i < len(rows):
        row = rows[i]
        id_vs = row[0]
        ip = row[1]
        state = row[2]
        if ip not in by_ip:
            by_ip[ip] = []
        state_str = "UNKNOWN"
        desc = "unknown[%s]" % state
        if state in _RS_STATE_MAP:
            state_str, desc = _RS_STATE_MAP[state]
        by_ip[ip].append({"id_virtual_service": id_vs, "state_str": state_str, "state_desc": desc})
        i = i + 1
    # Filter out items where ALL are disabled
    out = []
    for ip in by_ip:
        rservers = by_ip[ip]
        all_disabled = True
        i = 0
        while i < len(rservers):
            r = rservers[i]
            if not (r["state_str"] == "CRIT" and r["state_desc"] == "disabled"):
                all_disabled = False
                break
            i = i + 1
        if not all_disabled:
            out.append({
                "item": ip,
                "params": {},
                "metrics": []
            })
    return out

def _check(ctx, community, host, item):
    rows = _parse_realserver_section(ctx, community, host)
    # Find rows matching item as IP
    rservers = []
    i = 0
    while i < len(rows):
        r = rows[i]
        if r[1].strip() == item:
            rservers.append(r)
        i = i + 1
    if len(rservers) == 0:
        return {
            "state": "UNKNOWN",
            "msg": "Real server not found",
            "metrics": {},
            "details": ""
        }

    # Build results for each server — Checkmk yields one Result per server
    # We report the worst state among them
    worst_state = "OK"
    summaries = []
    i = 0
    while i < len(rservers):
        r = rservers[i]
        id_vs = r[0]
        ip = r[1]
        state = r[2]
        state_str = "UNKNOWN"
        desc = "unknown[%s]" % state
        if state in _RS_STATE_MAP:
            state_str, desc = _RS_STATE_MAP[state]
        # If CRIT appears, worst_state becomes CRIT; if OK + WARN -> WARN; etc.
        # For simplicity: CRIT > UNKNOWN > WARN > OK; we don't have WARN in mapping.
        # Checkmk mapping has OK/CRIT only — we assume no WARN state in original.
        # We just pick the worst:
        if state_str == "CRIT" and worst_state != "CRIT":
            worst_state = "CRIT"
        elif state_str == "UNKNOWN" and worst_state == "OK":
            worst_state = "UNKNOWN"
        # For the summary: use just desc (capitalized)
        summaries.append(desc.capitalize())
        i = i + 1

    msg = "; ".join(summaries)
    return {
        "state": worst_state,
        "msg": msg,
        "metrics": {},
        "details": ""
    }

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        discovery = _discover(ctx, community, host)
        return {
            "changed": False,
            "msg": "discovered %d real servers" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Normal check mode
    item = params.get("item", "")
    # For item "", we default to empty item (no real server selected), which yields UNKNOWN
    if item == "":
        return {
            "changed": False,
            "msg": "no item selected",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    result = _check(ctx, community, host, item)
    return {
        "changed": False,
        "msg": result["msg"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"]
        }
    }