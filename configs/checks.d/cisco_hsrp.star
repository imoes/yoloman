# cisco_hsrp — Checkmk HSRP group monitor, translated to read-only Starlark.
#
# This is an SNMP check. The Checkmk agent-based section reads the Cisco
# HSRP MIB (ciscoHsrpMIB, .1.3.6.1.4.1.9.9.106) via the HSRP group table
#   .1.3.6.1.4.1.9.9.106.1.2.1.1
# with columns:
#   .1  OIDEnd (the index: <ifIndex>.<group>)
#   .2  hsrpGrpIpAddress         (VIP, 11 in the fetch list above — see parse)
#   .13 hsrpGrpStandbyNextHop    (standby router IP)
#   .15 hsrpGrpState             (1 init .. 6 active)
# The fetch OIDs are [OIDEnd(), "11", "13", "14", "15", "16"], i.e. indices
# .1(.index), .11, .13, .14, .15, .16 — but OIDEnd() IS column .1, so the
# actual table columns walked are .1(index), .11, .13, .14, .15, .16.

# OID of the column that carries the bare index suffix (OIDEnd -> base.1).
_BASE = ".1.3.6.1.4.1.9.9.106.1.2.1.1"
_COL_INDEX = _BASE + ".1"      # OIDEnd: <ifIndex>.<group>
_COL_VIP = _BASE + ".11"       # hsrpGrpExtEntryIp? (used as VIP in source)
_COL_STANDBY = _BASE + ".13"
_COL_ACTROUTER = _BASE + ".12"
_COL_STATE = _BASE + ".15"     # hsrpGrpState
_COL_VMAC = _BASE + ".16"

# HSRP state enumeration (from the Checkmk source).
_HSRP_STATES = {
    1: "initial",
    2: "learn",
    3: "listen",
    4: "speak",
    5: "standby",
    6: "active",
}


def _snmp_get(ctx, host, community, oid):
    """Fetch a single scalar/leaf value via snmpget -Oqv (bare value)."""
    return ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )


def _snmp_walk(ctx, host, community, oid):
    """Walk a column via snmpwalk -Oqn (one line per row: OID value)."""
    return ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )


def _strip_type_tag(s):
    """Strip a possible leading '<TYPE>: ' from an snmp output value."""
    if s == None or s == "":
        return ""
    # net-snmp -Oqv already drops the tag; this is a defensive fallback.
    idx = s.find(": ")
    if idx != -1:
        rest = s[idx + 2:]
        # drop surrounding quotes if present
        if rest.startswith('"') and rest.endswith('"') and len(rest) >= 2:
            return rest[1:-1]
        return rest
    return s


def _is_cisco_hsrp_host(ctx, host, community):
    """Detect a Cisco device that has the HSRP MIB (mirrors detect())."""
    # Sysoid / sysDescr presence of 'cisco' plus existence of the HSRP table.
    sys_descr = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
    if sys_descr.rc != 0:
        return False
    desc = sys_descr.stdout.strip()
    if desc.lower().find("cisco") == -1:
        return False
    hsrp_marker = _snmp_get(ctx, host, community, ".1.3.6.1.4.1.9.9.106.1.1.1.0")
    if hsrp_marker.rc != 0:
        return False
    return True


def _parse_hsrp_row(line):
    """Parse one 'OID value' snmpwalk line into (oid, value)."""
    parts = line.split(" ", 1)
    if len(parts) != 2:
        return None
    return (parts[0], parts[1])


def _index_of(oid, col_oid):
    """Return the index suffix of an OID after its column base."""
    if oid == None or col_oid == None:
        return None
    if not oid.startswith(col_oid + "."):
        return None
    return oid[len(col_oid) + 1:]


def _walk_rows(ctx, host, community, col_oid):
    """Return {index: value} for a walked column."""
    res = _snmp_walk(ctx, host, community, col_oid)
    rows = {}
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parsed = _parse_hsrp_row(line)
        if parsed == None:
            continue
        oid, val = parsed
        idx = _index_of(oid, col_oid)
        if idx == None:
            continue
        rows[idx] = _strip_type_tag(val)
    return rows


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- DISCOVERY ---
    if params.get("_discover"):
        if not _is_cisco_hsrp_host(ctx, host, community):
            return {
                "changed": False,
                "msg": "no Cisco HSRP device found",
                "data": {"discovery": []},
            }

        # Build the per-group index list from the index column (base.1), then
        # read each other column keyed by that index (mirrors SNMPTree fetch).
        index_rows = _walk_rows(ctx, host, community, _COL_INDEX)
        # Also need the VIP column; if the index column is empty the table is
        # empty and HSRP is simply not configured/active enough to monitor.
        vip_rows = _walk_rows(ctx, host, community, _COL_VIP)
        state_rows = _walk_rows(ctx, host, community, _COL_STATE)

        # Correlate by index suffix: <ifIndex>.<group>.
        discovery = []
        seen = {}
        for idx in index_rows.keys():
            if idx == None:
                continue
            vip = vip_rows.get(idx, "")
            grp_state_raw = state_rows.get(idx, "")
            if grp_state_raw == "":
                continue
            if not grp_state_raw.lstrip("-").isdigit():
                continue
            grp_state = int(grp_state_raw)
            # Split <ifIndex>.<group> into its two components.
            dot = idx.rfind(".")
            if dot == -1:
                continue
            hsrp_grp = idx[dot + 1:]
            if hsrp_grp == "":
                continue
            # discovery only yields items in a working state (standby/active),
            # exactly like the Checkmk source.
            if grp_state not in [5, 6]:
                continue
            vip_grp = vip + "-" + hsrp_grp
            if vip_grp in seen:
                continue
            seen[vip_grp] = True
            discovery.append({
                "item": vip_grp,
                "params": {"group": hsrp_grp, "state": grp_state},
                "metrics": [],
            })

        return {
            "changed": False,
            "msg": "discovered %d HSRP groups" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK (single item) ---
    item = params.get("item", "")
    group_wanted = params.get("group", "")
    state_wanted = params.get("state", 0)

    if item == "":
        return {
            "changed": False,
            "msg": "no HSRP group item specified",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "no item parameter provided",
            },
        }

    if not _is_cisco_hsrp_host(ctx, host, community):
        return {
            "changed": False,
            "msg": "no Cisco HSRP device found at " + host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "HSRP device not reachable or not a Cisco device",
            },
        }

    # Fetch all columns once and correlate by index.
    index_rows = _walk_rows(ctx, host, community, _COL_INDEX)
    vip_rows = _walk_rows(ctx, host, community, _COL_VIP)
    state_rows = _walk_rows(ctx, host, community, _COL_STATE)

    for idx in index_rows.keys():
        if idx == None:
            continue
        vip = vip_rows.get(idx, "")
        grp_state_raw = state_rows.get(idx, "")
        if grp_state_raw == "" or not grp_state_raw.lstrip("-").isdigit():
            continue

        # Reconstruct the same item matching the Checkmk discovery logic.
        if "-" in item:
            vip_grp = vip + "-"
            dot = idx.rfind(".")
            hsrp_grp = idx[dot + 1:] if dot != -1 else ""
            vip_grp = vip_grp + hsrp_grp
        else:
            vip_grp = vip

        if vip_grp == item:
            grp_state = int(grp_state_raw)
            # state text for the summary (from hsrp_states map).
            state_name = _HSRP_STATES.get(grp_state, "unknown")

            # Replicate the Checkmk grading rules verbatim.
            if state_wanted in [3, 5, 6] and grp_state == state_wanted:
                st = "OK"
                msgtxt = "Redundancy Group %s is OK" % vip_grp
            elif grp_state in [5, 6]:
                st = "WARN"
                msgtxt = "Redundancy Group %s has failed over" % vip_grp
            else:
                st = "CRIT"
                msgtxt = "Redundancy Group %s" % vip_grp

            return {
                "changed": False,
                "msg": "%s, Status: %s" % (msgtxt, state_name),
                "data": {
                    "state": st,
                    "metrics": {},
                    "details": "HSRP group %s, state: %s (%s)" % (
                        vip_grp, state_name, str(grp_state)),
                },
            }

    # Item not found in the SNMP table.
    return {
        "changed": False,
        "msg": "HSRP Group not found in SNMP output",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "HSRP group %s is not present in the cHsrpGrpTable" % item,
        },
    }