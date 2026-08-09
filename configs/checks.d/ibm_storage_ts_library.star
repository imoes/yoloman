# Starlark translation of Checkmk check: ibm_storage_ts_library
# Reads the SAME underlying SNMP source the Checkmk plugin/agent reads.
# READ-ONLY: never mutates, never writes files, always changed=False.

IBM_STORAGE_TS_STATUS_NAME_MAP = {
    "1": "other",
    "2": "unknown",
    "3": "Ok",
    "4": "non-critical",
    "5": "critical",
    "6": "non-Recoverable",
}

IBM_STORAGE_TS_STATUS_NAGIOS_MAP = {
    "1": "WARN",
    "2": "WARN",
    "3": "OK",
    "4": "WARN",
    "5": "CRIT",
    "6": "CRIT",
}

IBM_STORAGE_TS_FAULT_NAGIOS_MAP = {
    "0": "OK",
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
    "4": "CRIT",
}


def _state_worst(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    oa = order.get(a, 3)
    ob = order.get(b, 3)
    if oa >= ob:
        return a
    return b


def _probe_ibm_system(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_info = ".1.3.6.1.4.1.2.6.210.1"
    base_status = ".1.3.6.1.4.1.2.6.210.2"
    base_lib = ".1.3.6.1.4.1.2.6.210.3.1.1"

    sysid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", "-On", "-Le", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysid.rc != 0:
        return None
    oid_val = sysid.stdout.strip()
    if not oid_val.endswith(".1.3.6.1.4.1.2.6.210"):
        return None

    info_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_info + ".1"],
        mutates=False,
    )
    if info_res.rc != 0:
        return None

    return {
        "host": host,
        "community": community,
        "base_info": base_info,
        "base_status": base_status,
        "base_lib": base_lib,
    }


def main(ctx, params):
    if params.get("_discover"):
        probe = _probe_ibm_system(ctx, params)
        if probe == None:
            return {"changed": False, "msg": "IBM Storage TS system not detected",
                    "data": {"discovery": [], "host_labels": {}}}

        host = probe["host"]
        community = probe["community"]
        base_lib = probe["base_lib"]

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_lib + ".1"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "IBM Storage TS system: no libraries found",
                    "data": {"discovery": []}}

        entries = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            if not oid.startswith(base_lib + ".1."):
                continue
            index = oid[len(base_lib + ".1."):]
            if index == "":
                continue
            entries.append(index)

        seen = {}
        discovery = []
        for index in entries:
            if index in seen:
                continue
            seen[index] = True
            discovery.append({
                "item": index,
                "params": {},
                "metrics": [],
            })

        return {
            "changed": False,
            "msg": "discovered %d libraries" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    item = params.get("item", "")

    probe = _probe_ibm_system(ctx, params)
    if probe == None:
        return {
            "changed": False,
            "msg": "IBM Storage TS system not detected (no IBM Storage TS product on host)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    host = probe["host"]
    community = probe["community"]
    base_lib = probe["base_lib"]

    # Read library columns for the requested item (index == item)
    get_entry = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_lib + ".1." + item],
        mutates=False,
    )
    get_status = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_lib + ".2." + item],
        mutates=False,
    )
    get_serial = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_lib + ".10." + item],
        mutates=False,
    )
    get_drive_count = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_lib + ".11." + item],
        mutates=False,
    )
    get_fault = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_lib + ".22." + item],
        mutates=False,
    )
    get_severity = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_lib + ".23." + item],
        mutates=False,
    )
    get_descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_lib + ".24." + item],
        mutates=False,
    )

    # If any value is missing/unavailable, the item does not exist -> UNKNOWN
    if (get_entry.rc != 0 or get_status.rc != 0 or get_serial.rc != 0 or
            get_drive_count.rc != 0 or get_fault.rc != 0 or
            get_severity.rc != 0 or get_descr.rc != 0):
        return {
            "changed": False,
            "msg": "no such library: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    entry = get_entry.stdout.strip()
    status = get_status.stdout.strip()
    serial = get_serial.stdout.strip()
    drive_count = get_drive_count.stdout.strip()
    fault = get_fault.stdout.strip()
    severity = get_severity.stdout.strip()
    descr = get_descr.stdout.strip()

    # Strip surrounding quotes if present
    if len(serial) >= 2 and serial[0] == '"' and serial[-1] == '"':
        serial = serial[1:-1]
    if len(descr) >= 2 and descr[0] == '"' and descr[-1] == '"':
        descr = descr[1:-1]

    state_device = IBM_STORAGE_TS_STATUS_NAGIOS_MAP.get(status, "UNKNOWN")
    fault_status = IBM_STORAGE_TS_FAULT_NAGIOS_MAP.get(severity, "UNKNOWN")
    overall = _state_worst(state_device, fault_status)

    status_name = IBM_STORAGE_TS_STATUS_NAME_MAP.get(status, "unknown")
    infotext = "Device %s, Status: %s, Drives: %s" % (serial, status_name, drive_count)
    if fault != "0":
        infotext += ", Fault: %s (%s)" % (descr, fault)

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": overall,
            "metrics": {},
            "details": "",
        },
    }