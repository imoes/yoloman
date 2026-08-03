# ra3s_sensors_power – read-only Starlark check module
# Reproduces Checkmk plugin "ra3s_sensors_power" (Power State %s).
# SNMP-only: discovers a single digital sensor item when an RA3S device is
# present AND the digital sensor is of type "TEMP_ACTIVE_POWER" (i.e. its
# OID suffix set matches the active-power variant). Reports OK/CRIT based on
# whether power is detected on the sensor. No thresholds are configurable
# (check_default_parameters is empty).

def _detect_ra3s(ctx, params):
    # SysObjectID must contain the AKCP enterprise prefix.
    sysid_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Ov", "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False)
    if sysid_res.rc != 0:
        return False
    sysid = sysid_res.stdout.strip()
    if sysid.find("1.3.6.1.4.1.20916") == -1:
        return False
    # SysDescr must contain "3S" (RA3S model).
    descr_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Ov", "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.2.1.1.1.0"],
        mutates=False)
    if descr_res.rc != 0:
        return False
    return descr_res.stdout.find("3S") != -1


def _sensor_type_count(row):
    # row is a list of string values from the digital sensor OID column.
    # Count how many values are digit-only to determine the sensor type:
    #   2 -> TEMP, 3 -> TEMP_ACTIVE_POWER, 4 -> TEMP_ANALOG,
    #   5 -> TEMP_EXTREME, 6 -> TEMP_HUMIDITY
    count = 0
    for v in row:
        if v.isdigit():
            count += 1
    return count


def _fetch_digital(ctx, params):
    # Walk the digital sensor base OID; -Oqn yields "<col_oid>.<idx> <val>".
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"),
         ".1.3.6.1.4.1.20916.1.13.1.2.1"],
        mutates=False)
    if res.rc != 0:
        return None
    rows = {}
    base = ".1.3.6.1.4.1.20916.1.13.1.2.1"
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        if oid.find(base + ".") != 0:
            continue
        suffix = oid[len(base) + 1:]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col = parts[0]
        idx = suffix[len(col) + 1:]
        bucket = rows.setdefault(idx, {})
        bucket[int(col)] = val.strip()
    # Reconstruct ordered row per index (cols 1..6).
    result = []
    for idx in sorted(rows.keys()):
        cols = rows[idx]
        ordered = []
        ok = True
        for c in [1, 2, 3, 4, 5, 6]:
            if c in cols:
                ordered.append(cols[c])
            else:
                ok = False
                break
        if ok and len(ordered) >= 2:
            result.append(ordered[:3])
    return result


def main(ctx, params):
    # Required host/community; absent means no SNMP target configured.
    if params.get("host") == None:
        return {"changed": False, "msg": "no host configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Discovery mode: enumerate items this host actually has.
    if params.get("_discover"):
        if not _detect_ra3s(ctx, params):
            return {"changed": False, "msg": "no RA3S device found",
                    "data": {"discovery": []}}
        sensors = _fetch_digital(ctx, params)
        if sensors == None:
            return {"changed": False, "msg": "no RA3S device found",
                    "data": {"discovery": []}}
        out = []
        for row in sensors:
            if _sensor_type_count(row) == 3:
                out.append({"item": "Sensor", "params": {},
                            "metrics": [], "service_labels": {}})
        return {"changed": False,
                "msg": "discovered %d power items" % len(out),
                "data": {"discovery": out}}

    # Check mode: evaluate one item ("Sensor" for the active-power sensor).
    item = params.get("item", "")
    if not _detect_ra3s(ctx, params):
        return {"changed": False, "msg": "no RA3S device found",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": ""}}
    sensors = _fetch_digital(ctx, params)
    if sensors == None:
        return {"changed": False, "msg": "no RA3S device found",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": ""}}

    # Find the active-power sensor row (count==3) for the requested item.
    target = None
    for row in sensors:
        if _sensor_type_count(row) == 3:
            target = row
            break
    if target == None:
        return {"changed": False, "msg": "no power sensor found",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": ""}}

    # col 3 is the power state boolean (STRING: "1" = detected).
    power_val = target[2] if len(target) > 2 else ""
    power_detected = power_val == "1"
    if power_detected:
        state = "OK"
        msg = "power detected"
    else:
        state = "CRIT"
        msg = "no power detected"
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}