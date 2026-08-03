# ===== translated check: cmk datapower_temp (SNMP) =====

def _to_float(s):
    if s == None or s == "":
        return None
    neg = False
    val = s
    if s.startswith("-"):
        neg = True
        val = s[1:]
    if not val.replace(".", "", 1).isdigit():
        return None
    f = float(s)
    return f


def _parse_sensor_row(row):
    # row: [name, value, warn, status, crit]
    if len(row) < 5:
        return None
    name = row[0]
    temp = row[1]
    warn = row[2]
    status = row[3]
    crit = row[4]
    if name == "" or temp == "":
        return None
    temp_f = _to_float(temp)
    warn_f = _to_float(warn)
    crit_f = _to_float(crit)
    dev_levels = None
    if warn_f != None and crit_f != None:
        dev_levels = (warn_f, crit_f)
    return {
        "name": name,
        "temp": temp_f,
        "warn": warn_f,
        "crit": crit_f,
        "status": status,
        "dev_levels": dev_levels,
    }


def _sensor_status_result(status):
    # DATAPOWER_TEMP_STATUS_MAPPING
    if status == "8":
        return ("CRIT", "device status: failure")
    elif status == "9":
        return ("UNKNOWN", "device status: noReading")
    elif status == "10":
        return ("CRIT", "device status: invalid")
    return None


def _eval_temperature(reading, levels, dev_levels):
    # upper-level semantics: WARN if reading >= warn, CRIT if reading >= crit
    warn = None
    crit = None
    if levels != None:
        warn = levels[0]
        crit = levels[1]
    if warn == None and dev_levels != None:
        warn = dev_levels[0]
    if crit == None and dev_levels != None:
        crit = dev_levels[1]
    if reading == None or warn == None or crit == None:
        return "UNKNOWN"
    if reading >= crit:
        return "CRIT"
    if reading >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = "1.3.6.1.4.1.14685.3.1.141.1"

    if params.get("_discover"):
        # --- DISCOVERY ---
        # Verify the device is a Datapower appliance (DETECT)
        sysoid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Ovqn", "-O0", host, "1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysoid_res.skipped or sysoid_res.rc != 0:
            return {"changed": False, "msg": "snmp unreachable", "data": {"discovery": []}}
        sysoid = sysoid_res.stdout.strip()
        dp_models = [
            "1.3.6.1.4.1.14685.1.8",
            "1.3.6.1.4.1.14685.1.7",
            "1.3.6.1.4.1.14685.1.3",
        ]
        is_datapower = False
        for m in dp_models:
            if sysoid == m:
                is_datapower = True
                break
        if not is_datapower:
            return {"changed": False, "msg": "not a Datapower device", "data": {"discovery": []}}

        # Walk the sensor name column
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-O0", host, base_oid + ".1"],
            mutates=False,
        )
        if res.skipped or res.rc != 0:
            return {"changed": False, "msg": "no temp sensors", "data": {"discovery": []}}

        discovery = []
        seen_items = set()
        col_base_name = base_oid + ".1"
        for line in res.stdout.splitlines():
            line = line.strip()
            if line == "":
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            line_oid = line[:sp]
            line_val = line[sp + 1:]
            if not line_oid.startswith(col_base_name + "."):
                continue
            index = line_oid[len(col_base_name) + 1:]
            if index == "":
                continue
            name = line_val
            if name.startswith("STRING: "):
                name = name[len("STRING: "):]
            name = name.strip('"').strip()
            name = name.strip("Temperature ")
            if name == "" or name in seen_items:
                continue
            seen_items.add(name)
            discovery.append({
                "item": name,
                "params": {"levels": (65.0, 70.0)},
                "metrics": ["temperature"],
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK ---
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-O0", host, base_oid + ".1"],
        mutates=False,
    )
    if res.skipped or res.rc != 0:
        return {
            "changed": False,
            "msg": "no temp sensors",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    col_base_name = base_oid + ".1"
    target_index = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        line_oid = line[:sp]
        line_val = line[sp + 1:]
        if not line_oid.startswith(col_base_name + "."):
            continue
        index = line_oid[len(col_base_name) + 1:]
        if index == "":
            continue
        name = line_val
        if name.startswith("STRING: "):
            name = name[len("STRING: "):]
        name = name.strip('"').strip()
        name = name.strip("Temperature ")
        if name == item:
            target_index = index
            break

    if target_index == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Read value, warn, status, crit columns for target_index via snmpget -Oqv
    def _get(col):
        r = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", "-O0", host, base_oid + "." + col + "." + target_index],
            mutates=False,
        )
        if r.skipped or r.rc != 0:
            return None
        v = r.stdout.strip()
        if v.startswith("STRING: "):
            v = v[len("STRING: "):]
        v = v.strip('"')
        return v

    temp_str = _get("2")
    warn_str = _get("3")
    status_str = _get("5")
    crit_str = _get("6")

    sensor = _parse_sensor_row([item, temp_str, warn_str, status_str, crit_str])
    if sensor == None or sensor["temp"] == None:
        return {
            "changed": False,
            "msg": "no temperature reading for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    levels = params.get("levels", (65.0, 70.0))
    st = _sensor_status_result(sensor["status"])
    if st != None:
        state_name = st[0]
        detail = st[1] + ", reading: %s" % sensor["temp"]
    else:
        state_name = _eval_temperature(sensor["temp"], levels, sensor["dev_levels"])
        detail = "Temperature %s: %s" % (item, sensor["temp"])

    return {
        "changed": False,
        "msg": detail,
        "data": {
            "state": state_name,
            "metrics": {"temperature": sensor["temp"]},
            "details": detail,
        },
    }