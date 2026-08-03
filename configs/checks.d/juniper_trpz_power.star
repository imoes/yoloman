# juniper_trpz_power — translated Checkmk check for yolo-man agent (Starlark)

# Power supply unit (PSU) states reported by Juniper TRPZ devices.
PSU_STATES = {
    1: "other",
    2: "unknown",
    3: "ac-failed",
    4: "dc-failed",
    5: "ac-ok-dc-ok",
}

# SNMP base OID for the juniper_trpz_power section.
PSU_BASE_OID = "1.3.6.1.4.1.14525.4.8.1.1.13.1.2.1"
PSU_NAME_COL = "3"
PSU_STATE_COL = "2"

# Juniper TRPZone sysObjectID prefix used by DETECT_JUNIPER_TRPZ.
JUNIPER_TRPZ_PREFIX = ".1.3.6.1.4.1.14525.3"
SYS_OID = ".1.3.6.1.2.1.1.2.0"


def _snmpget_str(ctx, community, host, oid):
    res = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c",
            community,
            "-Oqv",
            host,
            oid,
        ],
        mutates=False,
    )
    if res.rc == 127:
        return None  # net-snmp not installed
    if res.rc != 0:
        return None
    return res.stdout.strip() if res.stdout else ""


def _snmpwalk_table(ctx, community, host, base_oid):
    res = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c",
            community,
            "-Oqn",
            host,
            base_oid,
        ],
        mutates=False,
    )
    if res.rc == 127:
        return []  # net-snmp not installed
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        rows.append((oid, val))
    return rows


def main(ctx, params):
    discover = params.get("_discover")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if discover:
        # Confirm this is a Juniper TRPZone device before discovering items.
        sys_val = _snmpget_str(ctx, community, host, SYS_OID)
        if sys_val == None:
            return {"changed": False, "msg": "unable to reach SNMP agent",
                    "data": {"discovery": []}}
        if not sys_val.startswith(JUNIPER_TRPZ_PREFIX):
            return {"changed": False, "msg": "not a Juniper TRPZone device",
                    "data": {"discovery": []}}

        rows = _snmpwalk_table(ctx, community, host, PSU_BASE_OID + "." + PSU_NAME_COL)
        if rows == None:
            return {"changed": False, "msg": "SNMP unavailable",
                    "data": {"discovery": []}}

        discovery = []
        for oid, name_val in rows:
            idx = oid[len(PSU_BASE_OID) + 1 + len(PSU_NAME_COL) + 1:]
            if idx == "":
                continue
            discovery.append({
                "item": name_val,
                "params": {},
                "metrics": ["psu_state"],
            })

        return {
            "changed": False,
            "msg": "discovered %d PSUs" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    # Verify device identity for the check as well.
    sys_val = _snmpget_str(ctx, community, host, SYS_OID)
    if sys_val == None:
        return {"changed": False, "msg": "SNMP unreachable: " + host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not sys_val.startswith(JUNIPER_TRPZ_PREFIX):
        return {"changed": False, "msg": "not a Juniper TRPZone device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = _snmpwalk_table(ctx, community, host, PSU_BASE_OID + "." + PSU_NAME_COL)
    if rows == None:
        return {"changed": False, "msg": "SNMP unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_rows = _snmpwalk_table(ctx, community, host, PSU_BASE_OID + "." + PSU_STATE_COL)
    if state_rows == None:
        return {"changed": False, "msg": "SNMP unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the index for this item (by name column value).
    target_idx = None
    for oid, name_val in rows:
        if name_val == item:
            target_idx = oid[len(PSU_BASE_OID) + 1 + len(PSU_NAME_COL) + 1:]
            break

    if target_idx == None:
        return {"changed": False, "msg": "PSU not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Retrieve the state for this index from the state column.
    want_oid = PSU_BASE_OID + "." + PSU_STATE_COL + "." + target_idx
    state_val = _snmpget_str(ctx, community, host, want_oid)
    if state_val == None or state_val == "":
        return {"changed": False, "msg": "could not read PSU state for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not state_val.isdigit():
        return {"changed": False, "msg": "invalid PSU state value: " + state_val,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = int(state_val)
    label = PSU_STATES.get(state, "unknown")

    message = "Current state: " + label

    if state in [2, 3, 4]:
        return {"changed": False, "msg": message,
                "data": {"state": "CRIT", "metrics": {"psu_state": state}, "details": ""}}
    if state == 1:
        return {"changed": False, "msg": message,
                "data": {"state": "WARN", "metrics": {"psu_state": state}, "details": ""}}

    return {"changed": False, "msg": message,
            "data": {"state": "OK", "metrics": {"psu_state": state}, "details": ""}}