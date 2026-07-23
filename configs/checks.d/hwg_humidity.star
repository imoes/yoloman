# Map for device states (same as Checkmk source)
MAP_DEV_STATES = {
    "0": "invalid",
    "1": "normal",
    "2": "out of range low",
    "3": "out of range high",
    "4": "alarm low",
    "5": "alarm high",
}

# Map for units (not used directly but kept for completeness)
MAP_UNITS = {"1": "c", "2": "f", "3": "k", "4": "%"}


def _parse_hwg(stdout):
    """Parse hwg humidity agent output (SNMP lines) into dict indexed by item."""
    parsed = {}
    for line in stdout.splitlines():
        parts = line.split("|")
        if len(parts) != 5:
            continue
        index, descr, sensorstatus, current, unit = parts
        # Skip invalid humidity entries (sensorstatus != 0 and unit == "%")
        if sensorstatus != "0" and MAP_UNITS.get(unit, "") == "%":
            # Guard instead of try/except: check if current is numeric
            cleaned = current.strip()
            # Allow floats: check for digits and at most one dot
            if cleaned.replace(".", "", 1).isdigit() and cleaned.count(".") <= 1:
                humidity = float(cleaned)
                parsed[index] = {
                    "descr": descr,
                    "humidity": humidity,
                    "dev_status_name": MAP_DEV_STATES.get(sensorstatus, "n.a."),
                    "dev_status": sensorstatus,
                }
    return parsed


def _check_humidity(value, params):
    """
    Reproduce check_humidity logic (simplified).
    Returns (state, msg, metrics) where state is "OK", "WARN", or "CRIT".
    """
    warn = params.get("levels", (60.0, 70.0))
    warn_high = 60.0
    crit_high = 70.0

    if type(warn) == "list":
        if len(warn) >= 2:
            warn_high = warn[0]
            crit_high = warn[1]
    elif type(warn) == "float" or type(warn) == "int":
        warn_high = float(warn)
        crit_high = float(warn)
    # Handle tuple-like structure (tuples become lists in Starlark)
    elif type(warn) == "dict":
        warn_high = warn.get(0, 60.0)
        crit_high = warn.get(1, 70.0)

    if value >= crit_high:
        return ("CRIT", "Humidity %f%% (warn/crit at %f%%/%f%%)" %
                (value, warn_high, crit_high), {"humidity": value})
    if value >= warn_high:
        return ("WARN", "Humidity %f%% (warn/crit at %f%%/%f%%)" %
                (value, warn_high, crit_high), {"humidity": value})
    return ("OK", "Humidity %f%%" % value, {"humidity": value})


def main(ctx, params):
    if params.get("_discover"):
        # Discover humidity sensors via SNMP walk
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.21796.4.1.3.1"
        # Fetch all rows (oids 1,2,3,4,7 => 5 values per row)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1", base_oid + ".2", base_oid + ".3",
            base_oid + ".4", base_oid + ".7"
        ], mutates=False)
        if res.rc != 0:
            # SNMP unreachable -> no services
            return {"changed": False, "msg": "no humidity sensors discovered",
                    "data": {"discovery": []}}

        # Aggregate multi-OID output: group by index (line number)
        lines = res.stdout.splitlines()
        section = _parse_hwg(res.stdout)
        discovery = []
        for index, attrs in section.items():
            if attrs.get("humidity") != None:
                discovery.append({
                    "item": index,
                    "params": {"levels": (60.0, 70.0)},
                    "metrics": ["humidity"],
                })
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode (not discovery)
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.21796.4.1.3.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1", base_oid + ".2", base_oid + ".3",
        base_oid + ".4", base_oid + ".7"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _parse_hwg(res.stdout)
    if item not in section:
        return {
            "changed": False,
            "msg": "humidity sensor not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    data = section[item]
    humidity = data.get("humidity")
    if humidity == None:
        return {
            "changed": False,
            "msg": "humidity data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    state, summary, metrics = _check_humidity(humidity, params)
    details = "Description: %s, Status: %s" % (data.get("descr", ""), data.get("dev_status_name", ""))
    return {
        "changed": False,
        "msg": summary + " - " + details,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }