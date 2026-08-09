def _parse_snmpwalk(output):
    rows = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        rows.append((parts[0], " ".join(parts[1:])))
    return rows

def _get_oid_values(ctx, host, community, oids):
    """Walk multiple OIDs and return {oid: value}."""
    result = {}
    for oid in oids:
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc == 0:
            result[oid] = res.stdout.strip()
        elif res.rc == 127:
            fail("snmpget not found on this host")
        else:
            result[oid] = ""
    return result

def _walk_table(ctx, host, community, column_oid, index):
    """Walk a single column OID with index and return list of (full_oid, value)."""
    full_oid = column_oid + "." + index if index else column_oid
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, full_oid],
        mutates=False,
    )
    if res.rc == 0:
        return _parse_snmpwalk(res.stdout)
    return []

def _walk_column(ctx, host, community, column_oid):
    """Walk a whole column and return list of (index, value) tuples."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0:
        if res.rc == 127:
            fail("snmpwalk not found on this host")
        return []
    rows = _parse_snmpwalk(res.stdout)
    out = []
    for oid, val in rows:
        suffix = oid[len(column_oid):]
        idx = suffix[1:] if suffix.startswith(".") else suffix
        if idx:
            out.append((idx, val))
    return out

def _fetch_sensors(ctx, host, community):
    """Fetch sensor data from the Kentix device via SNMP.

    The agent plugin parses SNMP data from table .1.3.6.1.4.1.37954.1
    where each sensor is a row of 10 OIDs. We reproduce that by walking
    each column OID and correlating by index.
    """
    # OID columns:
    # .1 name (STRING)  .2 temp (INTEGER)  .3 humidity (INTEGER)
    # .4 dewpoint  .5 CO  .6 motion  .7 leakage  .8 digin2  .9 digout  .10 comError
    base = ".1.3.6.1.4.1.37954.1.2.7"
    cols = {
        "name": base + ".1",
        "temp": base + ".2",
        "humidity": base + ".3",
        "dewpoint": base + ".4",
        "co": base + ".5",
        "motion": base + ".6",
        "leakage": base + ".7",
    }
    # Walk the name column to discover all sensor indices
    name_rows = _walk_column(ctx, host, community, cols["name"])
    sensors = {}
    for idx, name_val in name_rows:
        if name_val == "":
            continue
        # Strip possible quotes from STRING values
        name = name_val.strip().strip('"')
        sensor = {"name": name}
        # Fetch each numeric column for this index
        for field in ["temp", "humidity", "leakage"]:
            vals = _walk_table(ctx, host, community, cols[field], idx)
            if vals and len(vals) >= 1:
                raw = vals[0][1]
                # snmpget -Oqv gives bare value; for INTEGER it's the number
                # for STRING we may have quotes
                cleaned = raw.strip().strip('"')
                sensor[field] = cleaned
        sensors[name] = sensor
    return sensors

def _grade_humidity(value, warn, crit):
    """Grade humidity: upper levels → WARN if >= warn, CRIT if >= crit."""
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    item = params.get("item", "")

    # --- Discovery mode ---
    if params.get("_discover"):
        sensors = _fetch_sensors(ctx, host, community)
        if not sensors:
            return {
                "changed": False,
                "msg": "no Kentix sensors found",
                "data": {"discovery": []},
            }
        discovery = []
        for name in sorted(sensors.keys()):
            discovery.append({
                "item": name,
                "params": {"warn": warn, "crit": crit},
                "metrics": ["humidity"],
            })
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- Check mode ---
    sensors = _fetch_sensors(ctx, host, community)
    if not sensors:
        return {
            "changed": False,
            "msg": "no Kentix sensors found on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensor = sensors.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    humidity_raw = sensor.get("humidity", "")
    if humidity_raw == "":
        return {
            "changed": False,
            "msg": "no humidity value for sensor: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    humidity = 0.0
    if humidity_raw.lstrip("-").isdigit():
        humidity = float(humidity_raw) / 10.0

    state = _grade_humidity(humidity, warn, crit)
    msg = "Humidity: %f%%" % humidity

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": "",
        },
    }