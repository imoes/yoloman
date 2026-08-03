def main(ctx, params):
    # --- helpers ----------------------------------------------------------
    # Checkmk check_levels_legacy_compatible: WARN if value >= warn (upper),
    # CRIT if value >= crit. Levels tuple default from check_default_parameters.
    def grade_upper(value, levels, sensor):
        if levels == None or len(levels) < 2:
            return ("OK", "")
        warn = levels[0]
        crit = levels[1]
        if value >= crit:
            return ("CRIT", " (warn=%f, crit=%f)" % (warn, crit))
        if value >= warn:
            return ("WARN", " (warn=%f, crit=%f)" % (warn, crit))
        return ("OK", " (warn=%f, crit=%f)" % (warn, crit))

    def saveint(s):
        if s == None:
            return 0
        stripped = s.strip()
        if stripped.lstrip("-").isdigit():
            return int(stripped)
        return 0

    # --- data source: Eaton UPS environment via SNMP ---------------------
    # Checkmk detect: sysObjectID equals one of the Eaton enterprise IDs.
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    def sysdescr_oid():
        return ".1.3.6.1.2.1.1.2.0"

    # The monitored product is an Eaton UPS. Verify presence first via
    # sysObjectID; absence => empty discovery / UNKNOWN, never OK.
    probe = ctx.run([
        "snmpget", "-v" + version, "-c", community, "-Oqv",
        host, sysdescr_oid(),
    ], mutates=False)
    if probe.rc != 0 or probe.stdout.strip() == "":
        # No SNMP device / not installed / unreachable -> not an Eaton UPS.
        if params.get("_discover"):
            return {"changed": False, "msg": "no Eaton UPS found (not installed)",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no Eaton UPS reachable (no sysObjectID)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sysObj = probe.stdout.strip()
    eaton_ids = [".1.3.6.1.4.1.705.1.2", ".1.3.6.1.4.1.534.1", ".1.3.6.1.4.1.705.1"]
    if sysObj not in eaton_ids:
        if params.get("_discover"):
            return {"changed": False, "msg": "device is not an Eaton UPS",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "device is not an Eaton UPS (sysObjectID mismatch)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # --- DISCOVERY MODE --------------------------------------------------
    if params.get("_discover"):
        # SimpleSNMPSection fetch: SNMPTree base=.1.3.6.1.4.1.534.1.6, oids 1,5,6
        res = ctx.run([
            "snmpget", "-v" + version, "-c", community, "-Oqv",
            host,
            ".1.3.6.1.4.1.534.1.6.1",  # temp
            ".1.3.6.1.4.1.534.1.6.5",  # remote temp
            ".1.3.6.1.4.1.534.1.6.6",  # humidity
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no Eaton enviroment data found",
                    "data": {"discovery": []}}
        # Single-service check: one item with empty name, metrics are the
        # three sensor perfdata names.
        defaults = {
            "temp": (40, 50),
            "remote_temp": (40, 50),
            "humidity": (65, 80),
        }
        entry = {
            "item": "",
            "params": {
                "temp": params.get("temp", defaults["temp"]),
                "remote_temp": params.get("remote_temp", defaults["remote_temp"]),
                "humidity": params.get("humidity", defaults["humidity"]),
            },
            "metrics": ["temp", "remote_temp", "humidity"],
        }
        return {"changed": False, "msg": "discovered 1 environment item",
                "data": {"discovery": [entry]}}

    # --- CHECK MODE ------------------------------------------------------
    # params from Checkmk check_default_parameters:
    # temp=(40,50), remote_temp=(40,50), humidity=(65,80)
    # SNMPTree oids [1]=temp, [5]=remote_temp, [6]=humidity
    res = ctx.run([
        "snmpget", "-v" + version, "-c", community, "-Oqv",
        host,
        ".1.3.6.1.4.1.534.1.6.1",  # temp
        ".1.3.6.1.4.1.534.1.6.5",  # remote temp
        ".1.3.6.1.4.1.534.1.6.6",  # humidity
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "could not read Eaton environment sensors",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values = res.stdout.splitlines()
    if len(values) < 3:
        return {"changed": False,
                "msg": "incomplete Eaton environment sensor data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    wert = [saveint(values[0]), saveint(values[1]), saveint(values[2])]

    defaults = {
        "temp": (40, 50),
        "remote_temp": (40, 50),
        "humidity": (65, 80),
    }
    # Order: temp, remote_temp, humidity (mirrors SNMPTree oids 1,5,6)
    sensors = [
        ("temp", "Temperature", " °C", defaults["temp"]),
        ("remote_temp", "Remote-Temperature", " °C", defaults["remote_temp"]),
        ("humidity", "Humidity", "%", defaults["humidity"]),
    ]

    details = ""
    msg_parts = []
    overall = "OK"
    metrics = {}
    for i, (sensor, sensor_name, unit_symbol, default_levels) in enumerate(sensors):
        levels = params.get(sensor)
        if levels == None:
            levels = default_levels
        value = wert[i]
        state, suffix = grade_upper(value, levels, sensor)
        metrics[sensor] = float(value)
        readable = "%f%s" % (value, unit_symbol)
        details = details + "%s: %s%s\n" % (sensor_name, readable, suffix)
        msg_parts.append("%s: %s%s" % (sensor_name, readable, suffix))
        if state == "CRIT":
            overall = "CRIT"
        elif state == "WARN" and overall != "CRIT":
            overall = "WARN"

    msg = "; ".join(msg_parts)
    return {"changed": False,
            "msg": msg,
            "data": {"state": overall, "metrics": metrics, "details": details}}