# climaveneta_temp — Checkmk SNMP temperature check, translated to read-only Starlark.
# Monitors Climaveneta pCO Gateway temperature sensors via SNMP.

CLIMAVENETA_SENSORS = {
    1: "Room",
    3: "Outlet Air 1",
    4: "Outlet Air 2",
    5: "Outlet Air 3",
    6: "Outlet Air 4",
    7: "Intlet Air 1",
    8: "Intlet Air 2",
    9: "Intlet Air 3",
    10: "Intlet Air 4",
    11: "Coil 1 Inlet Water",
    12: "Coil 2 Inlet Water",
    13: "Coil 1 Outlet Water",
    14: "Coil 2 Outlet Water",
    23: "Regulation Valve/Compressor",
    24: "Regulation Fan 1",
    25: "Regulation Fan 2",
    28: "Suction",
}

# OID for system description (used to detect pCO Gateway).
SYS_DESCR_OID = ".1.3.6.1.2.1.1.1.0"
# Base OID for the temperature sensor table.
SENSOR_BASE_OID = ".1.3.6.1.4.1.9839.2.1"

def _split_oid_index(sensor_id):
    # sensor_id looks like "<index>.2" or just "<index>"; take part before first dot.
    return sensor_id.split(".")[0]

def _is_pico_gateway(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_DESCR_OID],
        mutates=False,
    )
    if res.rc != 0:
        return False
    # -Oqv gives bare value; check it starts with "pCO Gateway".
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val == "pCO Gateway" or val.startswith("pCO Gateway")

def _walk_sensors(ctx, host, community):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, SENSOR_BASE_OID],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        # oid is like "<SENSOR_BASE_OID>.<index>.<col>"; index is after base.
        idx_start = len(SENSOR_BASE_OID) + 1
        if oid[:idx_start].endswith(SENSOR_BASE_OID):
            idx_part = oid[idx_start:]
            # idx_part is "<index>.<col>"; sensor_id_int is index.
            parts = idx_part.split(".")
            if len(parts) >= 2:
                sensor_id = parts[0]
                rows.append((sensor_id, int(sensor_id), value))
    return rows

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Probe for the real thing: pCO Gateway.
        if not _is_pico_gateway(ctx, host, community):
            return {"changed": False, "msg": "no pCO Gateway detected", "data": {"discovery": []}}
        rows = _walk_sensors(ctx, host, community)
        discovered = []
        for sensor_id, sensor_id_int, value in rows:
            if sensor_id_int in CLIMAVENETA_SENSORS and _is_positive(value):
                discovered.append({
                    "item": CLIMAVENETA_SENSORS[sensor_id_int],
                    "params": {"levels": (28.0, 30.0)},
                    "metrics": ["temperature"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovered),
            "data": {"discovery": discovered},
        }

    # Check mode: check one item.
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    levels = params.get("levels", (28.0, 30.0))
    warn = levels[0] if len(levels) > 0 else 28.0
    crit = levels[1] if len(levels) > 1 else 30.0

    # Confirm pCO Gateway presence.
    if not _is_pico_gateway(ctx, host, community):
        return {
            "changed": False,
            "msg": "no pCO Gateway detected",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = _walk_sensors(ctx, host, community)
    reading = None
    for sensor_id, sensor_id_int, value in rows:
        if CLIMAVENETA_SENSORS.get(sensor_id_int) == item:
            reading = _to_reading(value)
            break

    if reading == None:
        return {
            "changed": False,
            "msg": "no sensor reading for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = _grade(reading, warn, crit)
    return {
        "changed": False,
        "msg": "Temperature %s: %f C" % (item, reading),
        "data": {
            "state": state,
            "metrics": {"temperature": reading},
            "details": "",
        },
    }

def _is_positive(value):
    # value is a string numeric; treat > 0 as present.
    v = _safe_int(value)
    return v != None and v > 0

def _safe_int(s):
    s = s.strip()
    if s == "" or s == None:
        return None
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if s.isdigit():
        return int(s) * (-1 if neg else 1)
    return None

def _to_reading(value):
    v = _safe_int(value)
    if v == None:
        return None
    return float(v) / 10.0

def _grade(reading, warn, crit):
    if reading >= crit:
        return "CRIT"
    if reading >= warn:
        return "WARN"
    return "OK"