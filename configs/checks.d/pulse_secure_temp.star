def _discover_detect_oids():
    return [".1.3.6.1.2.1.1.2.0", ".1.3.6.1.4.1.12532.1.1.1.0"]

def _is_pulse_secure(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    for oid in _discover_detect_oids():
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc == 127:
            return False
        if res.rc != 0 or not res.stdout.strip():
            return False
    return True

def _fetch_temp_table(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    column_oid = ".1.3.6.1.4.1.12532.42"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqne", host, column_oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    temps = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        space = line.find(" ")
        if space < 0:
            continue
        oid_part = line[0:space]
        rest = line[space + 1:].strip()
        if not oid_part.startswith(column_oid + "."):
            continue
        index = oid_part[len(column_oid) + 1:]
        values = rest.split()
        raw = values[0]
        if raw.startswith('"') and raw.endswith('"'):
            raw = raw[1:-1]
        if raw.startswith("STRING:") or raw.startswith("INTEGER:"):
            colon = raw.find(":")
            raw = raw[colon + 1:].strip()
        try_val = raw
        temp_val = None
        if _is_int_like(try_val):
            temp_val = int(try_val)
        elif _is_float_like(try_val):
            temp_val = float(try_val)
        if temp_val != None:
            temps[index] = temp_val
    return temps

def _is_int_like(s):
    if len(s) == 0:
        return False
    return s.lstrip("-").isdigit()

def _is_float_like(s):
    if len(s) == 0:
        return False
    parts = s.split(".")
    if len(parts) == 2:
        if _is_int_like(parts[0]) and _is_int_like(parts[1]):
            return True
        if parts[0] == "-" and _is_int_like(parts[1]):
            return True
        return False
    return False

def main(ctx, params):
    if params.get("_discover"):
        if not _is_pulse_secure(ctx, params):
            return {
                "changed": False,
                "msg": "not a Pulse Secure device",
                "data": {"discovery": []},
            }
        temps = _fetch_temp_table(ctx, params)
        if temps == None:
            return {
                "changed": False,
                "msg": "failed to fetch temperature data",
                "data": {"discovery": []},
            }
        discovery = []
        for item in sorted(temps.keys()):
            discovery.append({
                "item": item,
                "params": {"levels": (70.0, 75.0)},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not _is_pulse_secure(ctx, params):
        return {
            "changed": False,
            "msg": "not a Pulse Secure device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    temps = _fetch_temp_table(ctx, params)
    if temps == None:
        return {
            "changed": False,
            "msg": "failed to fetch temperature data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if item not in temps:
        return {
            "changed": False,
            "msg": "temperature sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    reading = float(temps[item])
    levels = params.get("levels", (70.0, 75.0))
    warn = levels[0] if len(levels) >= 1 else 70.0
    crit = levels[1] if len(levels) >= 2 else 75.0
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {
        "changed": False,
        "msg": "Pulse Secure %s Temperature: %f C" % (item, reading),
        "data": {
            "state": state,
            "metrics": {"temperature": reading},
            "details": "Sensor %s: %f C (warn: %f, crit: %f)" % (
                item, reading, warn, crit,
            ),
        },
    }