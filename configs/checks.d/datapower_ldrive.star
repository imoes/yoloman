def _snmp_get(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc == 0:
        return res.stdout.strip()
    return ""

def _snmp_walk_table(ctx, community, host, column_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        space_idx = line.find(" ")
        if space_idx < 0:
            continue
        oid_full = line[:space_idx]
        value = line[space_idx + 1:]
        index = oid_full[len(column_oid) + 1:] if oid_full.startswith(column_oid + ".") else ""
        rows.append({"index": index, "value": value})
    return rows

def _detect_datapower(ctx, community, host):
    sys_oid = _snmp_get(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if not sys_oid:
        return False
    valid = [
        ".1.3.6.1.4.1.14685.1.3",
        ".1.3.6.1.4.1.14685.1.7",
        ".1.3.6.1.4.1.14685.1.8",
    ]
    return sys_oid in valid

def _fetch_ldrive_table(ctx, community, host):
    base = ".1.3.6.1.4.1.14685.3.1.259.1"
    col_controller = base + ".1"
    col_ldrive = base + ".2"
    col_raid = base + ".4"
    col_num_drives = base + ".5"
    col_status = base + ".6"
    controllers = _snmp_walk_table(ctx, community, host, col_controller)
    table = {}
    for entry in controllers:
        idx = entry["index"]
        table[idx] = {
            "controller": entry["value"],
            "ldrive": _snmp_get(ctx, community, host, col_ldrive + "." + idx) if idx else "",
            "raid_level": _snmp_get(ctx, community, host, col_raid + "." + idx) if idx else "",
            "num_drives": _snmp_get(ctx, community, host, col_num_drives + "." + idx) if idx else "",
            "status": _snmp_get(ctx, community, host, col_status + "." + idx) if idx else "",
        }
    return table

LDEAVE_STATUS = {
    "1": ("CRIT", "offline"),
    "2": ("CRIT", "partially degraded"),
    "3": ("CRIT", "degraded"),
    "4": ("OK", "optimal"),
    "5": ("WARN", "unknown"),
}

RAID_LEVEL = {
    "1": "0",
    "2": "1",
    "3": "1E",
    "4": "5",
    "5": "6",
    "6": "10",
    "7": "50",
    "8": "60",
    "9": "undefined",
}

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        if not _detect_datapower(ctx, community, host):
            return {"changed": False, "msg": "no IBM Datapower device detected", "data": {"discovery": []}}
        table = _fetch_ldrive_table(ctx, community, host)
        discovery = []
        count = 0
        for idx in sorted(table.keys()):
            entry = table[idx]
            if entry["controller"] == "" or entry["ldrive"] == "":
                continue
            item = entry["controller"] + "-" + entry["ldrive"]
            discovery.append({"item": item, "params": {}, "metrics": []})
            count = count + 1
        return {"changed": False, "msg": "discovered %d logical drives" % count, "data": {"discovery": discovery, "host_labels": {"cmk/devicename": "datapower"}}}
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if not _detect_datapower(ctx, community, host):
        return {"changed": False, "msg": "no IBM Datapower device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    table = _fetch_ldrive_table(ctx, community, host)
    for idx in sorted(table.keys()):
        entry = table[idx]
        if entry["controller"] == "" or entry["ldrive"] == "":
            continue
        check_item = entry["controller"] + "-" + entry["ldrive"]
        if check_item == item:
            status_code = entry["status"]
            state_txt = "unknown"
            state = "UNKNOWN"
            if status_code in LDEAVE_STATUS:
                state, state_txt = LDEAVE_STATUS[status_code]
            raid = entry["raid_level"]
            raid_level = RAID_LEVEL.get(raid, raid)
            num_drives = entry["num_drives"]
            infotext = "Status: %s, RAID Level: %s, Number of Drives: %s" % (state_txt, raid_level, num_drives)
            return {"changed": False, "msg": infotext, "data": {"state": state, "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "logical drive not found: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}