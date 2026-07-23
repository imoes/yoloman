BASE_OID = ".1.3.6.1.4.1.3699.1.1.9.1.4.1.1"

# type codes whose sensors are humidity (2=humidity, 32770=humidityCombo)
HUMIDITY_TYPE_CODES = ["2", "32770"]

# type codes whose raw SNMP values need /10 scaling
SCALED_TYPE_CODES = ["1", "3", "5", "32769"]

def _parse_snmp_val(raw):
    colon = raw.find(": ")
    if colon < 0:
        return raw.strip()
    val = raw[colon + 2:].strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val

def _to_float(s):
    if s == None or s == "":
        return None
    s = s.strip()
    if not s:
        return None
    t = s
    if t.startswith("-"):
        t = t[1:]
    if not t:
        return None
    parts = t.split(".")
    if len(parts) > 2:
        return None
    for p in parts:
        if not p.isdigit():
            return None
    return float(s)

def _parse_sensors(lines):
    rows = {}
    prefix = BASE_OID + "."
    for line in lines:
        line = line.strip()
        if not line:
            continue
        eq = line.find(" = ")
        if eq < 0:
            continue
        oid = line[:eq]
        raw_val = line[eq + 3:]
        if not oid.startswith(prefix):
            continue
        suffix = oid[len(prefix):]
        dot = suffix.find(".")
        if dot < 0:
            continue
        col = suffix[:dot]
        row = suffix[dot + 1:]
        if "." in row:
            continue
        if row not in rows:
            rows[row] = {}
        rows[row][col] = _parse_snmp_val(raw_val)

    sensors = {}
    for row in rows:
        cols = rows[row]
        idx = cols.get("1", row)
        stype = cols.get("2", "0")
        desc = cols.get("3", "")
        val = _to_float(cols.get("6"))
        mn = _to_float(cols.get("10"))
        mx = _to_float(cols.get("11"))

        if val == None:
            continue

        name = desc + " " + idx
        if stype in SCALED_TYPE_CODES:
            val = val / 10.0
            if mn != None:
                mn = mn / 10.0
            if mx != None:
                mx = mx / 10.0

        sensors[name] = {"type": stype, "value": val, "min": mn, "max": mx}

    return sensors

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID],
            mutates=False,
        )
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed: " + res.stderr,
                "data": {"discovery": []},
            }
        sensors = _parse_sensors(res.stdout.splitlines())
        items = []
        for name in sensors:
            s = sensors[name]
            if s["type"] in HUMIDITY_TYPE_CODES:
                items.append({
                    "item": name,
                    "params": {
                        "warn": 60.0,
                        "crit": 70.0,
                        "warn_lower": 30.0,
                        "crit_lower": 20.0,
                    },
                    "metrics": ["humidity"],
                })
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensors = _parse_sensors(res.stdout.splitlines())
    sensor = sensors.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    humidity = sensor["value"]
    dev_min = sensor["min"]
    dev_max = sensor["max"]

    warn = params.get("warn", dev_max if dev_max != None else 70.0)
    crit = params.get("crit", dev_max if dev_max != None else 80.0)
    warn_lower = params.get("warn_lower", dev_min if dev_min != None else 30.0)
    crit_lower = params.get("crit_lower", dev_min if dev_min != None else 20.0)

    state = "OK"
    if humidity >= crit or humidity <= crit_lower:
        state = "CRIT"
    elif humidity >= warn or humidity <= warn_lower:
        state = "WARN"

    msg = "Humidity: %f%%" % humidity
    if state != "OK":
        msg = msg + " (upper warn/crit %f%%/%f%%, lower warn/crit %f%%/%f%%)" % (
            warn, crit, warn_lower, crit_lower
        )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": "",
        },
    }