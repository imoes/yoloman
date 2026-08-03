# W&T WebIO device check (SNMP based)
# Translates Checkmk's wut_webio check to a read-only Starlark check module.

_EA12x6_BASE = "1.3.6.1.4.1.5040.1.2.51"
_EA2x2_BASE = "1.3.6.1.4.1.5040.1.2.52"
_EA12x12_BASE = "1.3.6.1.4.1.5040.1.2.4"

_OIDS_TO_FETCH = [
    "3.1.1.1.0",
    "1.3.1.1",
    "3.2.1.1.1",
    "1.3.1.4",
]


def _fetch_snmp_tree(ctx, base, community, host):
    # SNMPWalk with -Oqn gives clean numeric output, one line per row.
    # We fetch the full subtree starting at base + first OID.
    full_base = base + "." + _OIDS_TO_FETCH[0]
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, full_base],
        mutates=False,
    )
    if res.rc != 0:
        return None
    rows = {}
    for line in res.stdout.splitlines():
        # line format: "<oid> <value>"
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1]
        # relative oid: strip base prefix
        base_oid = base + "."
        if not oid.startswith(base_oid):
            continue
        rel = oid[len(base_oid):]
        rows[rel] = value
    return rows


def _build_table(ctx, base, community, host):
    # The OID layout (from _OIDS_TO_FETCH):
    # 3.1.1.1.0      -> device description (scalar, one row)
    # 1.3.1.1        -> input port index
    # 3.2.1.1.1      -> user defined description of every input
    # 1.3.1.4        -> state of the input
    #
    # These are columnar-ish. We interpret as a table where:
    #   column "idx" is _OIDS_TO_FETCH[1] = "1.3.1.1"
    #   column "port_name" is _OIDS_TO_FETCH[2] = "3.2.1.1.1"
    #   column "state" is _OIDS_TO_FETCH[3] = "1.3.1.4"
    # Index comes from the suffix after the column base.
    idx_col = _OIDS_TO_FETCH[1]
    name_col = _OIDS_TO_FETCH[2]
    state_col = _OIDS_TO_FETCH[3]

    # Fetch each column separately to correlate by index.
    idx_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + idx_col],
        mutates=False,
    )
    if idx_res.rc != 0:
        return None

    name_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + name_col],
        mutates=False,
    )
    state_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + state_col],
        mutates=False,
    )

    col_base = base + "."
    idx_map = {}
    for line in idx_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1]
        if not oid.startswith(col_base + idx_col + "."):
            continue
        index = oid[len(col_base + idx_col + "."):]
        idx_map[index] = val

    name_map = {}
    if name_res.rc == 0:
        for line in name_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1]
            if not oid.startswith(col_base + name_col + "."):
                continue
            index = oid[len(col_base + name_col + "."):]
            name_map[index] = val

    state_map = {}
    if state_res.rc == 0:
        for line in state_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1]
            if not oid.startswith(col_base + state_col + "."):
                continue
            index = oid[len(col_base + state_col + "."):]
            state_map[index] = val

    return idx_map, name_map, state_map


def _probe_device_description(ctx, base, community, host):
    # Scalar: base + "3.1.1.1.0"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".3.1.1.1.0"],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _translate_state(raw):
    if raw == "0":
        return "Off"
    if raw == "1":
        return "On"
    if raw == "":
        return "Unknown"
    return "Unknown"


def _get_state_value(state, evaluation_mode):
    if evaluation_mode == "as_discovered":
        # Determine the discovered state, then warn/crit logic:
        # Off -> CRIT(2) if it's the discovered state, else OK(0)
        # On -> OK(0)
        # Unknown -> UNKNOWN(3)
        off_val = 0 if state == "Off" else 2
        on_val = 0 if state == "On" else 2
        unknown_val = 0 if state == "Unknown" else 2
        eval_map = {"Off": off_val, "On": on_val, "Unknown": unknown_val}
    else:
        eval_map = evaluation_mode
    return eval_map.get(state, 3)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        found_any = False
        found_base = None
        idx_map = None
        name_map = None
        state_map = None
        description = ""
        for base in (_EA12x6_BASE, _EA2x2_BASE, _EA12x12_BASE):
            data = _build_table(ctx, base, community, host)
            if data == None:
                continue
            idx_map, name_map, state_map = data
            if len(idx_map) > 0:
                found_any = True
                found_base = base
                description = _probe_device_description(ctx, base, community, host)
                break

        if not found_any:
            return {"changed": False, "msg": "no W&T WebIO device found",
                    "data": {"discovery": []}}

        discovery = []
        for index in idx_map:
            port_name = name_map.get(index, "")
            item = description + " " + port_name if description else port_name
            raw_state = state_map.get(index, "")
            state = _translate_state(raw_state)
            discovery.append({
                "item": item,
                "params": {
                    "evaluation_mode": {
                        "Off": 2,
                        "On": 0,
                        "Unknown": 3,
                    },
                    "states_during_discovery": state,
                },
                "metrics": ["input_state"],
            })
        return {"changed": False,
                "msg": "discovered %d inputs" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    evaluation_mode = params.get("evaluation_mode", {
        "Off": 2,
        "On": 0,
        "Unknown": 3,
    })
    as_discovered = params.get("evaluation_mode") == "as_discovered"
    states_during_disc = params.get("states_during_discovery")

    found_base = None
    idx_map = None
    name_map = None
    state_map = None
    description = ""
    for base in (_EA12x6_BASE, _EA2x2_BASE, _EA12x12_BASE):
        data = _build_table(ctx, base, community, host)
        if data == None:
            continue
        idx_map, name_map, state_map = data
        if len(idx_map) > 0:
            found_base = base
            description = _probe_device_description(ctx, base, community, host)
            break

    if found_base == None:
        return {"changed": False, "msg": "no W&T WebIO device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the matching item
    matched_index = None
    matched_state = None
    for index in idx_map:
        port_name = name_map.get(index, "")
        candidate_item = description + " " + port_name if description else port_name
        if candidate_item == item:
            matched_index = index
            raw_state = state_map.get(index, "")
            matched_state = _translate_state(raw_state)
            break

    if matched_index == None:
        return {"changed": False, "msg": "input not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if as_discovered:
        state_val = _get_state_value(matched_state, "as_discovered")
    else:
        state_val = _get_state_value(matched_state, evaluation_mode)

    state_str = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}.get(state_val, "UNKNOWN")

    metric_map = {"On": 1, "Off": 0, "Unknown": 2}
    metric_val = metric_map.get(matched_state, 2)

    msg = "Input (Index: %s) is in state: %s" % (matched_index, matched_state)
    return {"changed": False, "msg": msg,
            "data": {"state": state_str, "metrics": {"input_state": metric_val}, "details": ""}}