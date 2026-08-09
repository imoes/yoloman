PRESENT_MAP = {1: "other", 2: "absent", 3: "present"}
STATUS_MAP = {
    1: ("CRIT", "Other"),
    2: ("OK", "Ok"),
    3: ("WARN", "Degraded"),
    4: ("CRIT", "Failed"),
}
PSU_STATUS = {
    1: "noError",
    2: "generalFailure",
    3: "bistFailure",
    4: "fanFailure",
    5: "tempFailure",
    6: "interlockOpen",
    7: "epromFailed",
    8: "vrefFailed",
    9: "dacFailed",
    10: "ramTestFailed",
    11: "voltageChannelFailed",
    12: "orringdiodeFailed",
    13: "brownOut",
    14: "giveupOnStartup",
    15: "nvramInvalid",
    16: "calibrationTableInvalid",
}
INPUTLINE_STATUS = {
    1: "noError",
    2: "lineOverVoltage",
    3: "lineUnderVoltage",
    4: "lineHit",
    5: "brownOut",
    6: "linePowerLoss",
}
BASE_OID = ".1.3.6.1.4.1.232.22.2.5.1.1.1"
COLUMN_OIDS = ["3", "16", "17", "10", "14", "15", "5"]
SYS_OID = ".1.3.6.1.2.1.1.2.0"
HP_BLADE_SYS = ".11.5.7.1.2"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    sys_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_OID
    ], mutates=False)
    if sys_res.rc != 0:
        return {
            "changed": False,
            "msg": "host not reachable or not an HP blade system",
            "data": {"discovery": []},
        }
    if HP_BLADE_SYS not in sys_res.stdout:
        return {
            "changed": False,
            "msg": "not an HP blade system (sysObjectID mismatch)",
            "data": {"discovery": []},
        }

    if params.get("_discover"):
        return _discover(ctx, params, host, community)
    return _check(ctx, params, host, community, item)


def _discover(ctx, params, host, community):
    rows = _fetch_all_columns(ctx, host, community)
    discovery = []
    idx = 0
    for col0 in rows.get(BASE_OID + ".3", []):
        if idx >= len(rows.get(BASE_OID + ".16", [])):
            break
        present_val = rows.get(BASE_OID + ".16", [])[idx]
        if present_val == None:
            break
        present_str = PRESENT_MAP.get(int(present_val), "unknown")
        if present_str == "present":
            discovery.append({
                "item": col0,
                "params": {},
                "metrics": ["output"],
            })
        idx += 1
    return {
        "changed": False,
        "msg": "discovered %d PSUs" % len(discovery),
        "data": {"discovery": discovery},
    }


def _check(ctx, params, host, community, item):
    rows = _fetch_all_columns(ctx, host, community)
    idx = -1
    items = rows.get(BASE_OID + ".3", [])
    for i, val in enumerate(items):
        if val == item:
            idx = i
            break
    if idx == -1:
        return {
            "changed": False,
            "msg": "PSU " + item + " not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    serial_list = rows.get(BASE_OID + ".5", [])
    part_list = rows.get(BASE_OID + ".6", [])
    spare_list = rows.get(BASE_OID + ".7", [])
    power_list = rows.get(BASE_OID + ".10", [])
    status_list = rows.get(BASE_OID + ".14", [])
    inputline_list = rows.get(BASE_OID + ".15", [])
    present_list = rows.get(BASE_OID + ".16", [])
    cond_list = rows.get(BASE_OID + ".17", [])

    present_val = present_list[idx] if idx < len(present_list) else "2"
    present_state = PRESENT_MAP.get(int(present_val), "unknown")
    if present_state != "present":
        return {
            "changed": False,
            "msg": "PSU was present but is not available anymore (Present state: %s)" % present_state,
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": "",
            },
        }

    status_val = status_list[idx] if idx < len(status_list) else "1"
    state, snmp_state = STATUS_MAP.get(int(status_val), ("UNKNOWN", "Unknown"))

    detail_output = ""
    power_val = power_list[idx] if idx < len(power_list) else "0"
    if state == "OK":
        detail_output = ", Output: %sW" % power_val
    else:
        cond_val = cond_list[idx] if idx < len(cond_list) else "0"
        if int(cond_val) >= 1:
            detail_output = " (%s)" % PSU_STATUS.get(4, "fanFailure")
        inputline_val = inputline_list[idx] if idx < len(inputline_list) else "0"
        if int(inputline_val) >= 1:
            detail_output = ", Inputline: %s" % INPUTLINE_STATUS.get(5, "brownOut")

    serial_val = serial_list[idx] if idx < len(serial_list) else ""
    summary = "PSU is %s%s (S/N: %s)" % (snmp_state, detail_output, serial_val)

    output_metric = float(power_val) if power_val else 0.0

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"output": output_metric},
            "details": "",
        },
    }


def _fetch_all_columns(ctx, host, community):
    columns = {
        "3": BASE_OID + ".3",
        "16": BASE_OID + ".16",
        "5": BASE_OID + ".5",
        "7": BASE_OID + ".7",
        "10": BASE_OID + ".10",
        "14": BASE_OID + ".14",
        "15": BASE_OID + ".15",
        "17": BASE_OID + ".17",
    }
    results = {}
    for col_short, col_oid in columns.items():
        walk_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid
        ], mutates=False)
        if walk_res.rc != 0:
            results[col_oid] = []
            continue
        values = []
        for line in walk_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) == 2:
                values.append(parts[1])
        results[col_oid] = values
    return results