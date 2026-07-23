BASE_OID = ".1.3.6.1.4.1.232.3.2.5.1.1"

MAP_CONDITION = {
    "0": "n/a",
    "1": "other",
    "2": "ok",
    "3": "degraded",
    "4": "failed",
}

MAP_STATUS = {
    "1": "other",
    "2": "ok",
    "3": "failed",
    "4": "predictive failure",
    "5": "erasing",
    "6": "erase done",
    "7": "erase queued",
    "8": "SSD wear out",
    "9": "not authenticated",
    "10": "spare",
}

MAP_SMART_STATUS = {
    "1": "other",
    "2": "ok",
    "3": "replace drive",
    "4": "replace drive SSD wear out",
}

MAP_TYPES = {
    "1": "other",
    "2": "parallel SCSI",
    "3": "SATA",
    "4": "SAS",
}

def _is_int(s):
    if s == "" or s == None:
        return False
    for i in range(len(s)):
        c = s[i]
        if c < "0" or c > "9":
            return False
    return True

def _map_val(mapping, value):
    result = mapping.get(value)
    if result == None:
        return "unknown(%s)" % value
    return result

def _parse_snmp_value(raw):
    if ": " not in raw:
        return raw.strip()
    parts = raw.split(": ", 1)
    val = parts[1].strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val

def _disksize(size_bytes):
    size = int(size_bytes)
    if size >= 1099511627776:
        return "%f TB" % (float(size) / 1099511627776.0)
    if size >= 1073741824:
        return "%f GB" % (float(size) / 1073741824.0)
    if size >= 1048576:
        return "%f MB" % (float(size) / 1048576.0)
    return "%d B" % size

def _fetch_drives(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("snmp_version", "2c")

    res = ctx.run(
        ["snmpwalk", "-v" + version, "-c", community, "-On", host, BASE_OID],
        mutates=False,
        ok_codes=[0, 1],
    )

    drives = {}
    prefix = BASE_OID + "."

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or " = " not in line:
            continue
        eq_idx = line.find(" = ")
        oid_part = line[:eq_idx].strip()
        raw_val = line[eq_idx + 3:]

        if not oid_part.startswith(prefix):
            continue

        remainder = oid_part[len(prefix):]
        dot_idx = remainder.find(".")
        if dot_idx < 0:
            continue
        col = remainder[:dot_idx]
        instance = remainder[dot_idx + 1:]

        val = _parse_snmp_value(raw_val)

        if instance not in drives:
            drives[instance] = {}
        drives[instance][col] = val

    return drives

def main(ctx, params):
    if params.get("_discover"):
        drives = _fetch_drives(ctx, params)
        discovery = []
        for instance in sorted(drives.keys()):
            d = drives[instance]
            cntlr = d.get("1", "")
            drv_idx = d.get("2", "")
            item = cntlr + "/" + drv_idx
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["ref_hours"],
            })
        return {
            "changed": False,
            "msg": "discovered %d physical drives" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    drives = _fetch_drives(ctx, params)

    target = None
    for instance in drives:
        d = drives[instance]
        cntlr = d.get("1", "")
        drv_idx = d.get("2", "")
        if cntlr + "/" + drv_idx == item:
            target = d
            break

    if target == None:
        return {
            "changed": False,
            "msg": "drive not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    condition_raw = target.get("37", "0")
    condition = _map_val(MAP_CONDITION, condition_raw)

    status_raw = target.get("6", "1")
    status = _map_val(MAP_STATUS, status_raw)

    smart_raw = target.get("57", "1")
    smart_status = _map_val(MAP_SMART_STATUS, smart_raw)

    bay = target.get("5", "")
    bus_number = target.get("50", "")
    ref_hours = target.get("9", "")
    size_raw = target.get("45", "0")
    size_bytes = int(size_raw) * 1048576 if _is_int(size_raw) else 0
    ref_hours_int = int(ref_hours) if _is_int(ref_hours) else 0

    if condition == "ok":
        state = "OK"
    elif condition == "degraded" or condition == "failed":
        state = "CRIT"
    else:
        state = "UNKNOWN"

    msg = (
        "Bay: %s, Bus number: %s, Status: %s, Smart status: %s, Ref hours: %s, Size: %s, Condition: %s"
        % (bay, bus_number, status, smart_status, ref_hours, _disksize(size_bytes), condition)
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"ref_hours": ref_hours_int},
            "details": "",
        },
    }