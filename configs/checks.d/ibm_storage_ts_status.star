def _snmp_get_str(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0 or res.skipped:
        return None
    out = res.stdout.strip()
    if out == "":
        return None
    return out


def _snmp_walk_str(ctx, host, community, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0 or res.skipped:
        return None
    lines = []
    for line in res.stdout.split("\n"):
        if line.strip() == "":
            continue
        lines.append(line)
    return lines


def _build_collection(ctx, host, community):
    info_oid = "1.3.6.1.4.1.2.6.210.1"
    status_oid = "1.3.6.1.4.1.2.6.210.2"
    lib_oid = "1.3.6.1.4.1.2.6.210.3.1.1"
    drive_oid = "1.3.6.1.4.1.2.6.210.3.2.1"

    sys_oid = "1.3.6.1.2.1.1.2.0"
    sys_val = _snmp_get_str(ctx, host, community, sys_oid)
    if sys_val == None or sys_val != ".1.3.6.1.4.1.2.6.210":
        return None

    info_raw = [
        _snmp_get_str(ctx, host, community, info_oid + ".1"),
        _snmp_get_str(ctx, host, community, info_oid + ".3"),
        _snmp_get_str(ctx, host, community, info_oid + ".4"),
    ]
    if info_raw[0] == None and info_raw[1] == None and info_raw[2] == None:
        return None

    status_raw = _snmp_get_str(ctx, host, community, status_oid + ".1")
    if status_raw == None:
        return None

    libraries = []
    lib_lines = _snmp_walk_str(ctx, host, community, lib_oid)
    if lib_lines != None:
        by_index = {}
        for line in lib_lines:
            sp = line.find(" ")
            if sp < 0:
                continue
            oid_full = line[:sp]
            val = line[sp + 1:]
            suffix = oid_full[len(lib_oid) + 1:]
            parts = suffix.split(".")
            if len(parts) != 2:
                continue
            col = parts[0]
            idx = parts[1]
            if idx not in by_index:
                by_index[idx] = {}
            by_index[idx][col] = val
        for idx in sorted(by_index.keys()):
            row = by_index[idx]
            entry = row.get("1", "")
            status = row.get("2", "")
            drive_count = row.get("10", "")
            fault = row.get("11", "")
            severity = row.get("22", "")
            descr = row.get("23", "")
            libraries.append({
                "entry": entry,
                "status": status,
                "serial": "",
                "drive_count": drive_count,
                "fault": fault,
                "severity": severity,
                "descr": descr,
            })

    drives = []
    drive_lines = _snmp_walk_str(ctx, host, community, drive_oid)
    if drive_lines != None:
        by_index = {}
        for line in drive_lines:
            sp = line.find(" ")
            if sp < 0:
                continue
            oid_full = line[:sp]
            val = line[sp + 1:]
            suffix = oid_full[len(drive_oid) + 1:]
            parts = suffix.split(".")
            if len(parts) != 2:
                continue
            col = parts[0]
            idx = parts[1]
            if idx not in by_index:
                by_index[idx] = {}
            by_index[idx][col] = val
        for idx in sorted(by_index.keys()):
            row = by_index[idx]
            entry = row.get("1", "")
            serial = row.get("10", "")
            write_warn = row.get("15", "")
            write_err = row.get("16", "")
            read_warn = row.get("17", "")
            read_err = row.get("18", "")
            drives.append({
                "entry": entry,
                "serial": serial,
                "write_warn": write_warn,
                "write_err": write_err,
                "read_warn": read_warn,
                "read_err": read_err,
            })

    return {
        "info": {"product": info_raw[0], "vendor": info_raw[1], "version": info_raw[2]},
        "status": status_raw,
        "libraries": libraries,
        "drives": drives,
    }


STATUS_NAME_MAP = {
    "1": "other", "2": "unknown", "3": "Ok", "4": "non-critical",
    "5": "critical", "6": "non-Recoverable",
}

STATUS_NAGIOS_MAP = {
    "1": "WARN", "2": "WARN", "3": "OK", "4": "WARN", "5": "CRIT", "6": "CRIT",
}

FAULT_NAGIOS_MAP = {
    "0": "OK", "1": "OK", "2": "WARN", "3": "CRIT", "4": "CRIT",
}


def _worst(a, b):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2}
    ra = rank.get(a, 0)
    rb = rank.get(b, 0)
    return a if ra >= rb else b


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        section = _build_collection(ctx, host, community)
        if section == None:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        discovery = []
        discovery.append({"item": "", "params": {}, "metrics": []})
        for library in section["libraries"]:
            discovery.append({"item": library["entry"], "params": {}, "metrics": []})
        for drive in section["drives"]:
            discovery.append({"item": drive["entry"], "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    check_name = params.get("_check_name", "ibm_storage_ts_status")

    section = _build_collection(ctx, host, community)
    if section == None:
        return {
            "changed": False,
            "msg": "not present on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if check_name == "ibm_storage_ts_status":
        st = section["status"]
        state = STATUS_NAGIOS_MAP.get(st, "UNKNOWN")
        name = STATUS_NAME_MAP.get(st, st)
        return {
            "changed": False,
            "msg": "Device Status: %s" % name,
            "data": {"state": state, "metrics": {}, "details": ""},
        }

    if check_name == "ibm_storage_ts_library":
        for library in section["libraries"]:
            if item == library["entry"]:
                st = library["status"]
                sev = library["severity"]
                state_device = STATUS_NAGIOS_MAP.get(st, "OK")
                fault_status = FAULT_NAGIOS_MAP.get(sev, "OK")
                state = _worst(state_device, fault_status)
                info = "Device %s, Status: %s, Drives: %s" % (
                    library["serial"], STATUS_NAME_MAP.get(st, st), library["drive_count"])
                if library["fault"] != "0":
                    info += ", Fault: %s (%s)" % (library["descr"], library["fault"])
                return {
                    "changed": False,
                    "msg": info,
                    "data": {"state": state, "metrics": {}, "details": ""},
                }
        return {
            "changed": False,
            "msg": "library not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if check_name == "ibm_storage_ts_drive":
        for drive in section["drives"]:
            if item == drive["entry"]:
                results = []
                overall = "OK"
                for counter, level, label in [
                    (drive["write_err"], "CRIT", "hard write errors"),
                    (drive["write_warn"], "WARN", "recovered write errors"),
                    (drive["read_err"], "CRIT", "hard read errors"),
                    (drive["read_warn"], "WARN", "recovered read errors"),
                ]:
                    if counter == "":
                        results.append("got empty string for %s" % label)
                    elif counter != "0":
                        results.append("%s %s" % (counter, label))
                        overall = _worst(overall, level)
                msg = "S/N: %s" % drive["serial"]
                if len(results) > 0:
                    msg = msg + ", " + ", ".join(results)
                return {
                    "changed": False,
                    "msg": msg,
                    "data": {"state": overall, "metrics": {}, "details": ""},
                }
        return {
            "changed": False,
            "msg": "drive not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "unknown check: %s" % check_name,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }