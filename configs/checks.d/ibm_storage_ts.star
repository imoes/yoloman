def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    check_submode = params.get("check_mode", "check")

    detect = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    is_ibm = (detect.rc == 0 and detect.stdout.strip() == ".1.3.6.1.4.1.2.6.210")

    info_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                        ".1.3.6.1.4.1.2.6.210.1.1", ".1.3.6.1.4.1.2.6.210.1.3", ".1.3.6.1.4.1.2.6.210.1.4"],
                       mutates=False)
    status_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2.6.210.2.1"],
                         mutates=False)

    if not is_ibm or info_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no IBM Storage TS device found", "data": {"discovery": []}}
        return {"changed": False, "msg": "no IBM Storage TS device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    info_lines = info_res.stdout.strip().split("\n")
    vendor = info_lines[0] if len(info_lines) > 0 else ""
    product = info_lines[1] if len(info_lines) > 1 else ""
    version = info_lines[2] if len(info_lines) > 2 else ""
    status_val = status_res.stdout.strip()

    lib_oid_base = ".1.3.6.1.4.1.2.6.210.3.1.1"
    lib_col_map = {"1": "entry", "2": "status", "10": "serial", "11": "fault",
                   "22": "drive_count", "23": "severity", "24": "descr"}
    lib_data = {}
    for col_oid, col_name in lib_col_map.items():
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                       lib_oid_base + "." + col_oid], mutates=False)
        for line in res.stdout.strip().split("\n"):
            if not line:
                continue
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            oid, val = sp
            prefix = lib_oid_base + "." + col_oid + "."
            if not oid.startswith(prefix):
                continue
            idx = oid[len(prefix):]
            if idx not in lib_data:
                lib_data[idx] = {}
            lib_data[idx][col_name] = val

    libraries_list = []
    for idx in sorted(lib_data):
        d = lib_data[idx]
        libraries_list.append({
            "entry": d.get("entry", ""),
            "status": d.get("status", ""),
            "serial": d.get("serial", ""),
            "drive_count": d.get("drive_count", ""),
            "fault": d.get("fault", ""),
            "severity": d.get("severity", ""),
            "descr": d.get("descr", ""),
        })

    drv_oid_base = ".1.3.6.1.4.1.2.6.210.3.2.1"
    drv_col_map = {"1": "entry", "10": "serial", "15": "write_warn", "16": "write_err",
                   "17": "read_warn", "18": "read_err"}
    drv_data = {}
    for col_oid, col_name in drv_col_map.items():
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                       drv_oid_base + "." + col_oid], mutates=False)
        for line in res.stdout.strip().split("\n"):
            if not line:
                continue
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            oid, val = sp
            prefix = drv_oid_base + "." + col_oid + "."
            if not oid.startswith(prefix):
                continue
            idx = oid[len(prefix):]
            if idx not in drv_data:
                drv_data[idx] = {}
            drv_data[idx][col_name] = val

    drives_list = []
    for idx in sorted(drv_data):
        d = drv_data[idx]
        drives_list.append({
            "entry": d.get("entry", ""),
            "serial": d.get("serial", ""),
            "write_warn": d.get("write_warn", ""),
            "write_err": d.get("write_err", ""),
            "read_warn": d.get("read_warn", ""),
            "read_err": d.get("read_err", ""),
        })

    status_name_map = {"1": "other", "2": "unknown", "3": "Ok", "4": "non-critical",
                       "5": "critical", "6": "non-Recoverable"}
    status_nagios_map = {"1": "WARN", "2": "WARN", "3": "OK", "4": "WARN", "5": "CRIT", "6": "CRIT"}
    fault_nagios_map = {"0": "OK", "1": "OK", "2": "WARN", "3": "CRIT", "4": "CRIT"}

    STATE_ORDER = ["OK", "WARN", "CRIT", "UNKNOWN"]

    def worst_state(s1, s2):
        i1 = STATE_ORDER.index(s1) if s1 in STATE_ORDER else 3
        i2 = STATE_ORDER.index(s2) if s2 in STATE_ORDER else 3
        return s1 if i1 >= i2 else s2

    if params.get("_discover"):
        discovery = []
        discovery.append({"item": "", "params": {}, "metrics": []})
        discovery.append({"item": "", "params": {}, "metrics": []})
        for lib in libraries_list:
            discovery.append({"item": lib.get("entry", ""), "params": {}, "metrics": []})
        for drv in drives_list:
            discovery.append({"item": drv.get("entry", ""), "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d services" % len(discovery),
                "data": {"discovery": discovery}}

    mode = check_submode
    if mode == "info":
        summary = "%s %s, Version %s" % (vendor, product, version)
        return {"changed": False, "msg": summary,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    if mode == "status":
        st = status_nagios_map.get(status_val, "UNKNOWN")
        nm = status_name_map.get(status_val, "unknown")
        return {"changed": False, "msg": "Device Status: %s" % nm,
                "data": {"state": st, "metrics": {}, "details": ""}}

    if mode == "library":
        for lib in libraries_list:
            if lib.get("entry", "") == item:
                state_dev = status_nagios_map.get(lib.get("status", ""), "UNKNOWN")
                fault_st = fault_nagios_map.get(lib.get("severity", ""), "UNKNOWN")
                state = worst_state(state_dev, fault_st)
                infotext = "Device %s, Status: %s, Drives: %s" % (
                    lib.get("serial", ""),
                    status_name_map.get(lib.get("status", ""), "unknown"),
                    lib.get("drive_count", ""),
                )
                if lib.get("fault", "0") != "0":
                    infotext += ", Fault: %s (%s)" % (lib.get("descr", ""), lib.get("fault", ""))
                return {"changed": False, "msg": infotext,
                        "data": {"state": state, "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "no library found for item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if mode == "drive":
        for drv in drives_list:
            if drv.get("entry", "") == item:
                parts = ["S/N: %s" % drv.get("serial", "")]
                worst = "OK"
                checks = [("write_err", "CRIT", "hard write errors"),
                          ("write_warn", "WARN", "recovered write errors"),
                          ("read_err", "CRIT", "hard read errors"),
                          ("read_warn", "WARN", "recovered read errors")]
                for counter_field, state_field, label in checks:
                    val = drv.get(counter_field, "")
                    if val == "":
                        worst = worst_state(worst, "UNKNOWN")
                    elif val != "0":
                        worst = worst_state(worst, state_field)
                        parts.append("%s %s" % (val, label))
                msg = "; ".join(parts)
                return {"changed": False, "msg": msg,
                        "data": {"state": worst, "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "no drive found for item: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": "unknown check mode: %s" % mode,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}