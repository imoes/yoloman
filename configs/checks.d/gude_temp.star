# Translated Checkmk check: checkmk.gude_temp
# SNMP-based temperature sensor check for GUDE equipment.
# READ-ONLY: never mutates=True, never ctx.file_write, always changed=False.

def _probe_gude_device(ctx, host, community):
    """Probe the SNMP sysObjectID to determine whether this is a GUDE device.

    Returns one of the GUDE enterprise IDs (e.g. "28507.19") if the host is a
    supported GUDE device, or None if it is not / SNMP is unavailable.
    A rc == 127 means the snmp tooling is missing.
    """
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    oid = res.stdout.strip()
    if not oid:
        return None
    # GUDE enterprise IDs: 28507.19, 28507.38, 28507.66, 28507.67
    for eid in ("28507.19", "28507.38", "28507.66", "28507.67"):
        if oid.startswith(".1.3.6.1.4.1." + eid):
            return eid
    return None


def _walk_temp_table(ctx, host, community, table):
    """Walk the GUDE temperature table for a given product table number.

    Returns a list of (index, temperature_in_celsius) tuples.
    Temperature readings are stored in tenths of a degree, so we divide by 10.
    """
    base = ".1.3.6.1.4.1.28507." + table + ".1.6.1.1"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, base + ".2"],
        mutates=False,
    )
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        # Format: "<OID> <value>" (numeric OID, no type tag, no '=' with -Oqv/-On)
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        oid = sp[0].strip()
        value_str = sp[1].strip()
        # Index is the OID suffix after "<base>.2"
        idx_prefix = base + ".2."
        if not oid.startswith(idx_prefix):
            continue
        index = oid[len(idx_prefix):]
        if not value_str.lstrip("-").isdigit():
            continue
        reading = float(value_str) / 10.0
        rows.append((index, reading))
    return rows


def _read_sensors(ctx, host, community):
    """Read all temperature sensors from all GUDE tables on this host.

    Returns a dict mapping "Sensor <index>" -> temperature (float, celsius).
    Sensors reporting -999.9 are excluded (not physically present / offline).
    """
    sensors = {}
    for table in ("19", "38", "66", "67"):
        for index, reading in _walk_temp_table(ctx, host, community, table):
            name = "Sensor " + index
            # Only include sensors that are actually reporting (-999.9 = offline)
            if reading != -999.9:
                sensors[name] = reading
    return sensors


def _grade_temperature(reading, warn, crit):
    """Grade a temperature reading against warn/crit levels.

    GUDE temperatures are "upper" levels: WARN if >= warn, CRIT if >= crit.
    Returns one of "OK", "WARN", "CRIT".
    """
    state = "OK"
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    return state


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    # Threshold params (Checkmk default levels: (35.0, 40.0))
    levels = params.get("levels", (35.0, 40.0))
    if type(levels) == "list":
        levels = tuple(levels)
    warn = levels[0] if len(levels) >= 2 else 35.0
    crit = levels[1] if len(levels) >= 2 else 40.0

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        # First, confirm this is actually a GUDE device via sysObjectID.
        eid = _probe_gude_device(ctx, host, community)
        if eid == None:
            # Not a GUDE device (or SNMP tooling missing / unreachable).
            # Absence is an answer: do not invent a placeholder item.
            return {
                "changed": False,
                "msg": "no GUDE device found at " + host,
                "data": {"discovery": []},
            }
        sensors = _read_sensors(ctx, host, community)
        discovery = []
        for name, reading in sensors.items():
            discovery.append({
                "item": name,
                "params": {"levels": [35.0, 40.0]},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE ---
    # Confirm the device is a GUDE device before reporting.
    eid = _probe_gude_device(ctx, host, community)
    if eid == None:
        return {
            "changed": False,
            "msg": "no GUDE device found at " + host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "The SNMP sysObjectID of this host does not match any supported GUDE device (enterprise IDs .1.3.6.1.4.1.28507.19/.38/.66/.67).",
            },
        }

    sensors = _read_sensors(ctx, host, community)
    if item == "" or item not in sensors:
        return {
            "changed": False,
            "msg": "no such sensor: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Sensor '" + item + "' was not found among the GUDE temperature sensors.",
            },
        }

    reading = sensors[item]
    state = _grade_temperature(reading, warn, crit)
    return {
        "changed": False,
        "msg": "Temperature: %f C" % reading,
        "data": {
            "state": state,
            "metrics": {"temperature": reading},
            "details": "Sensor " + item + ": " + ("%f" % reading) + " C",
        },
    }