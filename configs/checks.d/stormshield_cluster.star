# stormshield_cluster.star
# HA Status check for Checkmk Stormshield cluster devices (SNMP-based, read-only).
# Discovery enumerates HA members; check grades sync / not-replying / faulty-link state.

# OID base for the Stormshield HA cluster table (columns fetched together).
HA_BASE = ".1.3.6.1.4.1.11256.1.11"
# Column OIDs (relative to HA_BASE) fetched by SNMPTree: [1, 2, 3, 5, 6, 8].
HA_MEMBER_COL = ".1"
HA_NOT_REPLYING_COL = ".2"
HA_ACTIVE_COL = ".3"
HA_ETH_LINKS_COL = ".5"
HA_FAULTY_LINKS_COL = ".6"
HA_SYNC_COL = ".8"

# Detection OIDs (per DETECT_STORMSHIELD_CLUSTER).
SYS_OID = ".1.3.6.1.2.1.1.2.0"
STORMSHIELD_ENTERPRISE = ".1.3.6.1.4.1.11256"
NETSNMP_ENTERPRISE = ".1.3.6.1.4.1.8072"
STORMSHIELD_BASIC_INFO = ".1.3.6.1.4.1.11256.1.0.1.0"
STORMSHIELD_HA_INFO = ".1.3.6.1.4.1.11256.1.11.1.0"

# Sync status text and mapping (per Checkmk source).
SYNC_NAME = {
    "1": "Synced",
    "0": "Not Synced",
    "-1": "Unknown / Error",
    "": "Unknown / Error",
}
# State per sync value: OK / CRIT / UNKNOWN.
SYNC_STATE = {
    "1": "OK",
    "0": "CRIT",
    "-1": "UNKNOWN",
    "": "UNKNOWN",
}


def _get_sys_oid(ctx, host, community):
    """Resolve .1.3.6.1.2.1.1.2.0 to detect a Stormshield device.
    Returns the bare OID string or "" if unavailable."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_OID],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _is_stormshield(ctx, host, community):
    """Reproduce DETECT_STORMSHIELD_CLUSTER: sysOID is Stormshield/NetSNMP AND
    both Stormshield Basic Info and HA Info OIDs exist."""
    sys_oid = _get_sys_oid(ctx, host, community)
    if sys_oid == "":
        return False

    is_st = (
        sys_oid.startswith(NETSNMP_ENTERPRISE) or
        sys_oid == STORMSHIELD_ENTERPRISE + ".2.0" or
        sys_oid.startswith(STORMSHIELD_ENTERPRISE + ".1")
    )
    if not is_st:
        return False

    # exists() checks: probe each OID with snmpget; treat rc 0 as existing.
    res_b = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, STORMSHIELD_BASIC_INFO],
        mutates=False,
    )
    res_h = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, STORMSHIELD_HA_INFO],
        mutates=False,
    )
    return res_b.rc == 0 and res_h.rc == 0


def _walk_ha_table(ctx, host, community):
    """Walk the HA cluster table columns and group rows by their index.
    Returns a list of dicts, one per HA member, with the parsed columns."""
    columns = {
        HA_MEMBER_COL: [],
        HA_NOT_REPLYING_COL: [],
        HA_ACTIVE_COL: [],
        HA_ETH_LINKS_COL: [],
        HA_FAULTY_LINKS_COL: [],
        HA_SYNC_COL: [],
    }

    col_keys = list(columns.keys())
    for col_oid_suffix in col_keys:
        full_col_oid = HA_BASE + col_oid_suffix
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, full_col_oid],
            mutates=False,
        )
        if res.rc != 0:
            continue  # no rows for this column
        for line in res.stdout.splitlines():
            line = line.strip()
            if line == "":
                continue
            sp = line.find(" ")
            if sp == -1:
                continue
            line_oid = line[:sp]
            line_val = line[sp + 1:]
            # index = OID suffix after the column base OID (len(HA_BASE)+1 because of the dot).
            base_len = len(HA_BASE) + 1
            index = line_oid[base_len:] if len(line_oid) > base_len else line_oid
            columns[col_oid_suffix].append((index, line_val))

    # Group by index across all columns.
    by_index = {}
    for col_oid_suffix in col_keys:
        rows = columns[col_oid_suffix]
        for index, val in rows:
            if index not in by_index:
                by_index[index] = {}
            by_index[index][col_oid_suffix] = val

    members = []
    idx_keys = sorted(by_index.keys())
    for index in idx_keys:
        row = by_index[index]
        members.append({
            "number": row.get(HA_MEMBER_COL, ""),
            "not_replying": row.get(HA_NOT_REPLYING_COL, ""),
            "active": row.get(HA_ACTIVE_COL, ""),
            "eth_links": row.get(HA_ETH_LINKS_COL, ""),
            "faulty_links": row.get(HA_FAULTY_LINKS_COL, ""),
            "sync": row.get(HA_SYNC_COL, ""),
        })
    return members


def _grade_not_replying(val):
    """Return (state, count_int). Non-zero count => CRIT."""
    n = 0
    if val != "" and val.lstrip("-").isdigit():
        n = int(val)
    state = "CRIT" if n > 0 else "OK"
    return state, n


def _grade_faulty(val):
    """Return (state, count_int). Non-zero faulty => CRIT."""
    n = 0
    if val != "" and val.lstrip("-").isdigit():
        n = int(val)
    state = "CRIT" if n > 0 else "OK"
    return state, n


def _strip_quotes(s):
    out = s
    if len(out) >= 2 and out[0] == "'" and out[-1] == "'":
        out = out[1:-1]
    elif len(out) >= 2 and out[0] == '"' and out[-1] == '"':
        out = out[1:-1]
    return out


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # === DISCOVERY MODE ===
    if params.get("_discover"):
        if not _is_stormshield(ctx, host, community):
            return {"changed": False, "msg": "not a Stormshield HA device", "data": {"discovery": []}}

        members = _walk_ha_table(ctx, host, community)
        discovery = []
        for m in members:
            number = _strip_quotes(m["number"])
            discovery.append({
                "item": number,
                "params": {"warn": 80, "crit": 90},
                "metrics": ["sync_ok", "not_replying", "faulty_links"],
            })
        return {
            "changed": False,
            "msg": "discovered %d HA members" % len(discovery),
            "data": {"discovery": discovery},
        }

    # === CHECK MODE (single item) ===
    item = params.get("item", "")

    if not _is_stormshield(ctx, host, community):
        return {
            "changed": False,
            "msg": "not a Stormshield HA device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    members = _walk_ha_table(ctx, host, community)
    if len(members) == 0:
        return {
            "changed": False,
            "msg": "no Stormshield HA members found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Select the member matching `item` (member number), fall back to first row.
    target = None
    if item != "":
        for m in members:
            if _strip_quotes(m["number"]) == item:
                target = m
                break
    if target == None:
        target = members[0]

    number = _strip_quotes(target["number"])
    active = _strip_quotes(target["active"])
    eth_links = _strip_quotes(target["eth_links"])
    sync_raw = _strip_quotes(target["sync"])

    sync_state = SYNC_STATE.get(sync_raw, "UNKNOWN")
    sync_name = SYNC_NAME.get(sync_raw, "Unknown / Error")

    nr_state, nr_count = _grade_not_replying(_strip_quotes(target["not_replying"]))
    fl_state, fl_count = _grade_faulty(_strip_quotes(target["faulty_links"]))

    # Overall verdict: CRIT if any sub-state is CRIT, UNKNOWN if any is UNKNOWN,
    # WARN if any is WARN, else OK.
    states = [sync_state, nr_state, fl_state]
    if "CRIT" in states:
        overall = "CRIT"
    elif "UNKNOWN" in states:
        overall = "UNKNOWN"
    elif "WARN" in states:
        overall = "WARN"
    else:
        overall = "OK"

    msg = "Sync Status: %s | Member: %s, Active: %s, Links used: %s | Not replying: %d | Faulty: %d" % (
        sync_name, number, active, eth_links, nr_count, fl_count,
    )

    # metrics: plain numbers only.
    sync_ok = 1 if sync_state == "OK" else 0
    metrics = {
        "sync_ok": sync_ok,
        "not_replying": nr_count,
        "faulty_links": fl_count,
    }

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall,
            "metrics": metrics,
            "details": "sync=%s sync_state=%s not_replying=%d faulty=%d" % (
                sync_name, sync_state, nr_count, fl_count,
            ),
        },
    }