# Huawei OSN interface check (SNMP-based, read-only)
# Source OIDs from OPTIX-GLOBAL-NGWDM-MIB sdh_pathDataPm*
# Walks the path performance table and reports per-interface counters.

BASE_OID = ".1.3.6.1.4.1.2011.2.25.3.40.50.96.50.1"

# column OID -> human-readable metric name
COLS = {
    "3.200": "name",        # sdh_pathDataPmPara          (0)  -- also used as item/index
    "4.113": "in_ucast",    # pmRXUNICAST                (1)
    "4.114": "in_mcast",    # pmRXMULCAST                (2)
    "4.115": "in_bcast",    # pmRXBRDCAST                (3)
    "4.116": "out_ucast",   # pmTXUNICAST                (4)
    "4.117": "out_mcast",   # pmTXMULCAST                (5)
    "4.118": "out_bcast",   # pmTXBRDCAST                (6)
    "4.200": "in_octets",   # pmRXOCTETS                 (7)
    "4.199": "out_octets",  # pmTXOCTETS                 (8)
    "4.944": "in_err",      # pmRXPBAD                   (9)
    "4.945": "out_err",     # pmTXPBAD                  (10)
}

# column base OID (without the name column) for per-index re-query
COL_OIDS = [
    "4.113", "4.114", "4.115", "4.116", "4.117", "4.118",
    "4.200", "4.199", "4.944", "4.945",
]


def _walk(ctx, community, host, col_oid):
    """snmpwalk -Oqn for a column OID; returns list of (index, value)."""
    oid = BASE_OID + "." + col_oid
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On",
                   host, oid], mutates=False)
    rows = []
    base = oid
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        line_oid = line[:sp]
        value = line[sp + 1:].strip()
        # numeric OID: suffix after the column base
        if line_oid.startswith(base + "."):
            idx = line_oid[len(base) + 1:]
        else:
            idx = ""
        rows.append((idx, value))
    return rows


def _get(ctx, community, host, col_oid, idx):
    """snmpget -Oqv for a single cell."""
    oid = BASE_OID + "." + col_oid + "." + idx
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-On",
                   host, oid], mutates=False)
    if res.rc != 0:
        return None
    v = res.stdout.strip()
    return v


def _to_int(s):
    if s == None:
        return 0
    s = s.strip()
    if s == "" or s == "No more variables left in this walk":
        return 0
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    if not s.isdigit():
        # might be a quoted hex string from some MIBs; strip quotes
        if s.startswith('"') and s.endswith('"'):
            s = s[1:-1]
        if not s.isdigit():
            return 0
    val = int(s)
    return -val if neg else val


def _interface_exists(ctx, community, host):
    """Probe: is this Huawei OSN device reachable via SNMP?"""
    # Use the name column (3.200) which must be present for the table to exist.
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On",
                   host, BASE_OID + ".3.200"], mutates=False)
    if res.rc == 0 and res.stdout.strip() != "":
        return True
    if res.rc == 2 or res.rc == 127:
        return False
    return False


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")

    if params.get("_discover"):
        if not _interface_exists(ctx, community, host):
            return {"changed": False, "msg": "no Huawei OSN interface data",
                    "data": {"discovery": []}}

        names = _walk(ctx, community, host, "3.200")
        discovery = []
        for (idx, value) in names:
            name = value.strip().strip('"')
            if name == "":
                name = idx
            discovery.append({
                "item": name,
                "params": {},
                "metrics": ["in_octets", "out_octets", "in_ucast",
                            "out_ucast", "in_mcast", "out_mcast", "in_bcast",
                            "out_bcast", "in_err", "out_err"],
            })
        return {"changed": False,
                "msg": "discovered %d interfaces" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE -----------------------------------------------------------
    if not _interface_exists(ctx, community, host):
        return {"changed": False,
                "msg": "no Huawei OSN interface data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Resolve item -> index using the name column walk.
    names = _walk(ctx, community, host, "3.200")
    target_idx = None
    for (idx, value) in names:
        nm = value.strip().strip('"')
        if nm == "":
            nm = idx
        if nm == item:
            target_idx = idx
            break
    if target_idx == None and item != "":
        # Fallback: treat the item itself as a numeric index.
        target_idx = item

    if target_idx == None:
        return {"changed": False,
                "msg": "interface not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather all columns for this single index.
    metrics = {}
    for col in COLS:
        if col == "3.200":
            continue
        val = _get(ctx, community, host, col, target_idx)
        metrics[COLS[col]] = _to_int(val)

    # Determine operational state: if out_octets+in_octets are both zero
    # and errors are zero, the interface is administratively down / no traffic.
    in_oct = metrics.get("in_octets", 0)
    out_oct = metrics.get("out_octets", 0)
    in_err = metrics.get("in_err", 0)
    out_err = metrics.get("out_err", 0)

    state = "OK"
    if in_err > 0 or out_err > 0:
        state = "WARN"

    msg = "Traffic: in %d oct/s, out %d oct/s, in_err %d, out_err %d" % (
        in_oct, out_oct, in_err, out_err)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}