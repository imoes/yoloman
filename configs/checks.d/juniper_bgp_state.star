# juniper_bgp_state.star — translated Checkmk check → read-only Starlark check module

# BGP session state (RFC 1771) numeric → text
_BGP_STATE_MAP = {
    "0": "undefined",
    "1": "idle",
    "2": "connect",
    "3": "active",
    "4": "opensent",
    "5": "openconfirm",
    "6": "established",
}

# BGP operational state
_BGP_OP_STATE_MAP = {
    "0": "undefined",
    "1": "halted",
    "2": "running",
}

# SNMP table base + columns (from SNMPTree fetch)
_BGP_BASE_OID = ".1.3.6.1.4.1.2636.5.1.1.2.1.1.1"
_COL_STATE = "2"
_COL_OPER = "3"
_COL_PEERING = "11"

_STATE_METRIC = {
    "undefined": 0,
    "idle": 1,
    "connect": 2,
    "active": 3,
    "opensent": 4,
    "openconfirm": 5,
    "established": 6,
}

_OPER_METRIC = {
    "undefined": 0,
    "halted": 1,
    "running": 2,
}

_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}


def _clean_ipv4(addr):
    parts = addr.split(".")
    if len(parts) != 4:
        return addr
    out = []
    for p in parts:
        if not p.isdigit():
            return addr
        out.append(p)
    return ".".join(out)


def _clean_ipv6(addr):
    if len(addr) != 32:
        return addr
    # verify all hex
    valid = True
    for i in range(0, 32, 2):
        pair = addr[i:i + 2]
        if not pair.isdigit() and pair.lower() not in ("a", "b", "c", "d", "e", "f"):
            # check full 2-char hex
            ok = True
            for c in pair:
                if c.lower() not in "0123456789abcdef":
                    ok = False
                    break
            if not ok:
                valid = False
                break
    if not valid:
        return addr
    ints = []
    for i in range(0, 32, 2):
        ints.append(int(addr[i:i + 2], 16))
    hextets = []
    for i in range(0, 16, 2):
        hextets.append("%x%x" % (ints[i], ints[i + 1]))
    cleaned = []
    for h in hextets:
        stripped = h.lstrip("0")
        if stripped == "":
            stripped = "0"
        cleaned.append(stripped)
    return ":".join(cleaned)


def _create_item(peering_entry):
    if len(peering_entry) == 4:
        return _clean_ipv4(peering_entry)
    if len(peering_entry) == 16:
        return _clean_ipv6(peering_entry)
    parts = peering_entry.split(".")
    hex_parts = []
    for p in parts:
        if p.isdigit():
            hex_parts.append("%X" % int(p))
        else:
            hex_parts.append(p)
    return " ".join(hex_parts)


def _walk_oid_indexed(ctx, host, community, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    rows = []
    if res.rc != 0:
        return rows
    prefix = column_oid + "."
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        if oid.startswith(prefix):
            index = oid[len(prefix):]
        else:
            index = ""
        rows.append({"index": index, "oid": oid, "value": value})
    return rows


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        sysobj = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if not sysobj or not sysobj.startswith(".1.3.6.1.4.1.2636."):
            return {"changed": False, "msg": "not a Juniper device", "data": {"discovery": []}}

        peering_rows = _walk_oid_indexed(ctx, host, community, _BGP_BASE_OID + "." + _COL_PEERING)
        if not peering_rows:
            return {"changed": False, "msg": "no BGP peers discovered", "data": {"discovery": []}}

        discovery = []
        for pr in peering_rows:
            item = _create_item(pr["value"])
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["bgp_state", "operational_state"],
            })
        return {
            "changed": False,
            "msg": "discovered %d BGP peers" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE ---
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_rows = _walk_oid_indexed(ctx, host, community, _BGP_BASE_OID + "." + _COL_STATE)
    oper_rows = _walk_oid_indexed(ctx, host, community, _BGP_BASE_OID + "." + _COL_OPER)
    peering_rows = _walk_oid_indexed(ctx, host, community, _BGP_BASE_OID + "." + _COL_PEERING)

    if not state_rows or not oper_rows or not peering_rows:
        return {
            "changed": False,
            "msg": "juniper_bgp_state not available: no BGP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_map = {}
    for r in state_rows:
        state_map[r["index"]] = r["value"]
    oper_map = {}
    for r in oper_rows:
        oper_map[r["index"]] = r["value"]
    peering_map = {}
    for r in peering_rows:
        peering_map[r["index"]] = r["value"]

    target_index = None
    for idx in peering_map:
        if _create_item(peering_map[idx]) == item:
            target_index = idx
            break

    if target_index == None:
        return {
            "changed": False,
            "msg": "no BGP peer: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_code = state_map.get(target_index, "0").strip()
    oper_code = oper_map.get(target_index, "0").strip()
    state_txt = _BGP_STATE_MAP.get(state_code, "undefined")
    oper_txt = _BGP_OP_STATE_MAP.get(oper_code, "undefined")

    # Grade BGP session state
    if state_txt == "established":
        status = "OK"
    elif state_txt == "undefined":
        status = "UNKNOWN"
    else:
        status = "CRIT"

    # If operational state is not "running", override to OK
    if oper_txt != "running":
        status = "OK"

    # Grade operational state
    if oper_txt == "running":
        op_status = "OK"
    elif oper_txt == "undefined":
        op_status = "UNKNOWN"
    else:
        op_status = "WARN"

    final_state = status
    if _RANK.get(op_status, 3) > _RANK.get(status, 0):
        final_state = op_status

    metrics = {
        "bgp_state": _STATE_METRIC.get(state_txt, 0),
        "operational_state": _OPER_METRIC.get(oper_txt, 0),
    }

    summary = "Status with peer %s is %s, operational: %s" % (item, state_txt, oper_txt)
    details = "BGP state: %s\nOperational state: %s" % (state_txt, oper_txt)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": final_state,
            "metrics": metrics,
            "details": details,
        },
    }