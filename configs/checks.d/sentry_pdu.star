DEVICE_STATES_V4 = {
    0: {"state": "OK", "status": "normal"},
    1: {"state": "CRIT", "status": "disabled"},
    2: {"state": "CRIT", "status": "purged"},
    5: {"state": "WARN", "status": "reading"},
    6: {"state": "WARN", "status": "settle"},
    7: {"state": "CRIT", "status": "not found"},
    8: {"state": "CRIT", "status": "lost"},
    9: {"state": "CRIT", "status": "read error"},
    10: {"state": "CRIT", "status": "no comm"},
    11: {"state": "CRIT", "status": "pwr error"},
    12: {"state": "CRIT", "status": "breaker tripped"},
    13: {"state": "CRIT", "status": "fuse blown"},
    14: {"state": "CRIT", "status": "low alarm"},
    15: {"state": "WARN", "status": "low warning"},
    16: {"state": "WARN", "status": "high warning"},
    17: {"state": "CRIT", "status": "high alarm"},
    18: {"state": "CRIT", "status": "alarm"},
    19: {"state": "CRIT", "status": "under limit"},
    20: {"state": "CRIT", "status": "over limit"},
    21: {"state": "CRIT", "status": "nvm fail"},
    22: {"state": "CRIT", "status": "profile error"},
    23: {"state": "CRIT", "status": "conflict"},
}

_STATES_INT_TO_READABLE = {
    0: "off",
    1: "on",
    2: "off wait",
    3: "on wait",
    4: "off error",
    5: "on error",
    6: "no comm",
}

OID_SYSCONTACT_V4 = ".1.3.6.1.2.1.1.2.0"
OID_SYSCONTACT_V4_VALUE = ".1.3.6.1.4.1.1718.4"
OID_BASE_V4 = ".1.3.6.1.4.1.1718.4.1.3"
OID_COL_V4_NAME = "3.1.2"
OID_COL_V4_STATE = "2.1.3"
OID_COL_V4_POWER = "3.1.3"

OID_SYSCONTACT_V3_VALUE = ".1.3.6.1.4.1.1718.3"
OID_BASE_V3 = ".1.3.6.1.4.1.1718.3.2.2.1"
OID_COL_V3_NAME = "3"
OID_COL_V3_STATE = "5"
OID_COL_V3_POWER = "12"


def _strip_type_tag(value):
    idx = value.find(": ")
    if idx != -1:
        value = value[idx + 2:]
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[len(value) - 1] == '"':
        value = value[1:len(value) - 1]
    return value


def _snmpwalk_parse_idx_lines(lines):
    result = {}
    for line in lines:
        s = line.strip()
        if not s:
            continue
        sp = s.find(" ")
        if sp == -1:
            continue
        oid = s[:sp]
        value = s[sp + 1:]
        result[oid] = value
    return result


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        sys_oid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_SYSCONTACT_V4],
            mutates=False,
        )
        version_detected = None
        if sys_oid_res.rc == 0:
            sys_oid_val = sys_oid_res.stdout.strip()
            if sys_oid_val == OID_SYSCONTACT_V4_VALUE:
                version_detected = "v4"
        else:
            if sys_oid_res.rc == 127:
                return {
                    "changed": False,
                    "msg": "snmpget not available",
                    "data": {"discovery": []},
                }

        if version_detected == "v4":
            walk_res = ctx.run(
                [
                    "snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                    OID_BASE_V4 + "." + OID_COL_V4_NAME,
                ],
                mutates=False,
            )
            entries = _snmpwalk_parse_idx_lines(walk_res.stdout.splitlines())
            discovery = []
            for oid in sorted(entries.keys()):
                idx = oid[len(OID_BASE_V4 + "." + OID_COL_V4_NAME) + 1:]
                name_val = _strip_type_tag(entries[oid])
                metrics = []
                if name_val:
                    power_oid = OID_BASE_V4 + "." + OID_COL_V4_POWER + "." + idx
                    pres = ctx.run(
                        ["snmpget", "-v2c", "-c", community, "-Oqv", host, power_oid],
                        mutates=False,
                    )
                    if pres.rc == 0 and pres.stdout.strip():
                        metrics = ["power"]
                discovery.append({
                    "item": name_val,
                    "params": {},
                    "metrics": metrics,
                })
            return {
                "changed": False,
                "msg": "discovered %d plugs" % len(discovery),
                "data": {"discovery": discovery},
            }

        if version_detected == None:
            sys_oid_res_v3 = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_SYSCONTACT_V4],
                mutates=False,
            )
            if sys_oid_res_v3.rc == 0:
                val = sys_oid_res_v3.stdout.strip()
                if val == OID_SYSCONTACT_V3_VALUE:
                    version_detected = "v3"

        if version_detected == "v3":
            walk_res = ctx.run(
                [
                    "snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                    OID_BASE_V3 + "." + OID_COL_V3_NAME,
                ],
                mutates=False,
            )
            entries = _snmpwalk_parse_idx_lines(walk_res.stdout.splitlines())
            discovery = []
            for oid in sorted(entries.keys()):
                idx = oid[len(OID_BASE_V3 + "." + OID_COL_V3_NAME) + 1:]
                name_val = _strip_type_tag(entries[oid])
                metrics = []
                if name_val:
                    power_oid = OID_BASE_V3 + "." + OID_COL_V3_POWER + "." + idx
                    pres = ctx.run(
                        ["snmpget", "-v2c", "-c", community, "-Oqv", host, power_oid],
                        mutates=False,
                    )
                    if pres.rc == 0 and pres.stdout.strip():
                        metrics = ["power"]
                discovery.append({
                    "item": name_val,
                    "params": {},
                    "metrics": metrics,
                })
            return {
                "changed": False,
                "msg": "discovered %d plugs" % len(discovery),
                "data": {"discovery": discovery},
            }

        return {
            "changed": False,
            "msg": "Sentry PDU not detected on host",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_oid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_SYSCONTACT_V4],
        mutates=False,
    )
    version = None
    if sys_oid_res.rc == 0:
        val = sys_oid_res.stdout.strip()
        if val == OID_SYSCONTACT_V4_VALUE:
            version = "v4"
        elif val == OID_SYSCONTACT_V3_VALUE:
            version = "v3"
    else:
        if sys_oid_res.rc == 127:
            return {
                "changed": False,
                "msg": "snmpget not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    if version == None:
        return {
            "changed": False,
            "msg": "Sentry PDU not detected on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if version == "v4":
        base = OID_BASE_V4
        col_name = OID_COL_V4_NAME
        col_state = OID_COL_V4_STATE
        col_power = OID_COL_V4_POWER
    else:
        base = OID_BASE_V3
        col_name = OID_COL_V3_NAME
        col_state = OID_COL_V3_STATE
        col_power = OID_COL_V3_POWER

    name_walk_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + col_name],
        mutates=False,
    )
    name_entries = _snmpwalk_parse_idx_lines(name_walk_res.stdout.splitlines())
    idx = None
    for oid in sorted(name_entries.keys()):
        prefix = base + "." + col_name + "."
        if oid.startswith(prefix):
            candidate_idx = oid[len(prefix):]
            cand_name = _strip_type_tag(name_entries[oid])
            if cand_name == item:
                idx = candidate_idx
                break
    if idx == None:
        return {
            "changed": False,
            "msg": "no such plug: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + col_state + "." + idx],
        mutates=False,
    )
    if state_res.rc != 0:
        return {
            "changed": False,
            "msg": "state not available for plug " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    state_str = state_res.stdout.strip()
    state_str = _strip_type_tag(state_str)
    if not state_str or not state_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid state for plug " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    pdu_state = int(state_str)

    power_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + col_power + "." + idx],
        mutates=False,
    )
    power = None
    if power_res.rc == 0:
        p_str = power_res.stdout.strip()
        p_str = _strip_type_tag(p_str)
        if p_str and p_str.isdigit():
            power = int(p_str)

    if version == "v4":
        if pdu_state in DEVICE_STATES_V4:
            mapping = DEVICE_STATES_V4[pdu_state]
            verdict = mapping["state"]
            summary = "Status: " + mapping["status"]
        else:
            verdict = "UNKNOWN"
            summary = "Status: " + str(pdu_state)
    else:
        readable = _STATES_INT_TO_READABLE.get(pdu_state, "unknown")
        required_state = params.get("required_state")
        if required_state != None and required_state != "" and readable != required_state:
            verdict = "CRIT"
            summary = "Status: " + readable
        else:
            verdict = "OK"
            summary = "Status: " + readable

    metrics = {}
    if power != None and power > 0:
        summary = summary + " Power: " + str(power) + " Watt"
        metrics = {"power": power}

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": verdict, "metrics": metrics, "details": ""},
    }