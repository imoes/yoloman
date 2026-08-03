def main(ctx, params):
    if params.get("_discover"):
        sysOID = _get_sysOID(ctx, params)
        if sysOID == None:
            return {"changed": False, "msg": "device not present",
                    "data": {"discovery": []}}
        if not (startswith(sysOID, ".1.3.6.1.4.1.21239.5.1") or
                startswith(sysOID, ".1.3.6.1.4.1.21239.42.1")):
            return {"changed": False, "msg": "not a watchdog device",
                    "data": {"discovery": []}}
        section = _parse(ctx, params)
        if section == {} or not section.get("general"):
            return {"changed": False, "msg": "no watchdog sensors found",
                    "data": {"discovery": []}}
        discovery = []
        for key in section.get("general", {}):
            discovery.append({"item": key, "params": {}, "metrics": []})
        for key in section.get("temp", {}):
            discovery.append({"item": key, "params": {"warn": 70, "crit": 80},
                              "metrics": ["temperature"]})
        for key in section.get("humidity", {}):
            discovery.append({"item": key, "params": {"warn": 50, "crit": 55,
                              "warn_lower": 10, "crit_lower": 15},
                              "metrics": ["humidity"]})
        for key in section.get("dew", {}):
            discovery.append({"item": key, "params": {"warn": 50, "crit": 60},
                              "metrics": ["dew_point"]})
        return {"changed": False,
                "msg": "discovered %d watchdog sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _parse(ctx, params)
    if section == {} or not section.get("general"):
        return {"changed": False, "msg": "no watchdog sensors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item.startswith("Temperature") or item.startswith("Dew point"):
        return _check_temp(item, params, section)
    if item.startswith("Humidity"):
        return _check_humidity(item, params, section)
    return _check_general(item, section)


def startswith(s, prefix):
    return s != None and s.startswith(prefix)


def _get_sysOID(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                   ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmpget(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                  mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmpwalk(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
                  mutates=False)
    if res.rc != 0:
        return None
    return res.stdout


def _parse(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res1 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                    ".1.3.6.1.4.1.21239.5.1.1.2.0",
                    ".1.3.6.1.4.1.21239.5.1.1.7.0"], mutates=False)
    if res1.rc != 0:
        return {}
    general_vals = res1.stdout.strip().split("\n")
    if len(general_vals) < 2:
        return {}
    version_str = general_vals[0]
    availability = general_vals[1]

    if availability != "1":
        return {}

    temp_unit = "C"
    if version_str == "0" or version_str == "":
        temp_unit = "F"

    table_raw = _snmpwalk(ctx, params, ".1.3.6.1.4.1.21239.5.1.2.1")
    if table_raw == None:
        return {}

    version = 0
    parts = version_str.split(".")
    digits = ""
    for p in parts:
        digits = digits + p
    version = int(digits) if digits.isdigit() else 0

    parsed = {"general": {}, "temp": {}, "humidity": {}, "dew": {}}

    for line in table_raw.splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        oid_val = f[0]
        val = " ".join(f[1:])
        oid_parts = oid_val.split(".")
        if len(oid_parts) < 12:
            continue
        idx = oid_parts[12]
        col = oid_parts[11]

        if version <= 300:
            if col == "3":
                descr = val
                parsed["general"]["Watchdog " + idx] = {
                    "descr": descr, "availability": ("1",)}
            elif col == "6":
                parsed["temp"]["Temperature " + idx] = (val, temp_unit)
            elif col == "7":
                parsed["humidity"]["Humidity " + idx] = val
            elif col == "8":
                parsed["dew"]["Dew point " + idx] = (val, temp_unit)
        else:
            if col == "3":
                descr = val
                parsed["general"]["Watchdog " + idx] = {
                    "descr": descr, "availability": ("1",)}
            elif col == "6":
                parsed["temp"]["Temperature " + idx] = (val, temp_unit)
            elif col == "7":
                parsed["humidity"]["Humidity " + idx] = val

    return parsed


def _check_general(item, section):
    data = section.get("general", {}).get(item)
    if data == None:
        return {"changed": False, "msg": item + " not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    descr = data.get("descr", "")
    availability = data.get("availability", ("0",))[0]
    state_readable = _AVAILABILITY_MAP.get(availability, ("UNKNOWN", "unknown"))[1]
    st = _AVAILABILITY_MAP.get(availability, ("UNKNOWN", "unknown"))[0]
    msg = state_readable
    if descr != "":
        msg = msg + ", Location: " + descr
    return {"changed": False, "msg": msg,
            "data": {"state": st, "metrics": {}, "details": ""}}


def _check_temp(item, params, section):
    data = None
    if item.startswith("Temperature"):
        data = section.get("temp", {}).get(item)
    elif item.startswith("Dew point"):
        data = section.get("dew", {}).get(item)
    if data == None:
        return {"changed": False, "msg": item + " not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value_str, unit = data
    reading = float(value_str) / 10.0
    if unit == "F":
        reading = 5.0 / 9.0 * (reading - 32)
    warn = params.get("warn", 70)
    crit = params.get("crit", 80)
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"
    metric_name = "dew_point" if item.startswith("Dew point") else "temperature"
    return {"changed": False,
            "msg": "%s: %f%s" % (item, reading, unit.lower()),
            "data": {"state": state, "metrics": {metric_name: reading}, "details": ""}}


def _check_humidity(item, params, section):
    data = section.get("humidity", {}).get(item)
    if data == None:
        return {"changed": False, "msg": item + " not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    humidity = int(data)
    warn, crit = params.get("levels", (50.0, 55.0))
    warn_lower, crit_lower = params.get("levels_lower", (10.0, 15.0))
    if not (crit_lower < humidity and humidity < crit):
        state = "CRIT"
    elif not (warn_lower < humidity and humidity < warn):
        state = "WARN"
    else:
        state = "OK"
    summary = "%f%%" % humidity
    if state != "OK":
        if humidity >= warn:
            summary = summary + " (warn/crit at %s/%s)" % (warn, crit)
        else:
            summary = summary + " (warn/crit below %s/%s)" % (warn_lower, crit_lower)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"humidity": humidity}, "details": ""}}


_AVAILABILITY_MAP = {
    "0": ("CRIT", "unavailable"),
    "1": ("OK", "available"),
    "2": ("WARN", "partially unavailable"),
}