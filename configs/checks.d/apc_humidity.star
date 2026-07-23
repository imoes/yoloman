# ===== module constants (defined at top level per Starlark rules) =====
DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_VALUE = ".1.3.6.1.4.1.318"

SNMP_BASE = ".1.3.6.1.4.1.318.1.1.10.4.2.3.1"
OID_NAME = ".3"
OID_HUMIDITY = ".6"

# Checkmk defaults for humidity thresholds
DEFAULT_WARN = 60.0
DEFAULT_CRIT = 65.0
DEFAULT_WARN_LOWER = 40.0
DEFAULT_CRIT_LOWER = 35.0


def _saveint(i_str):
    """Tries to cast a string to an integer and return it. In case this
    fails, it returns 0."""
    if i_str.isdigit():
        return int(i_str)
    return 0


def main(ctx, params):
    # === DISCOVERY MODE ===
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            SNMP_BASE
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        # Parse output: each line is "OID = STRING: value" or similar.
        # We need lines where OID ends with .3 (name) and .6 (humidity).
        # We'll collect name/humidity pairs.
        lines = res.stdout.splitlines()
        name_map = {}  # OID suffix -> name string
        humidity_map = {}  # OID suffix -> humidity string

        for line in lines:
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            if not oid_part.startswith(SNMP_BASE + "."):
                continue
            suffix = oid_part[len(SNMP_BASE) + 1:]  # e.g., "3" or "6"

            # Extract value after colon/space (strip type prefix like "STRING:" or "INTEGER:")
            if value_part.startswith("STRING: "):
                value = value_part[8:].strip().strip('"')
            elif value_part.startswith("INTEGER: "):
                value = value_part[9:].strip()
            else:
                value = value_part

            if suffix == "3":
                name_map[suffix] = value
            elif suffix == "6":
                humidity_map[suffix] = value

        # Build list of discovered items: all items with humidity >= 0
        discovery_items = []
        for suffix, humidity_str in humidity_map.items():
            humidity_val = _saveint(humidity_str)
            if humidity_val >= 0:
                item = name_map.get(suffix, "")
                if item == "":
                    item = suffix
                discovery_items.append({
                    "item": item,
                    "params": {
                        "levels": [DEFAULT_WARN, DEFAULT_CRIT],
                        "levels_lower": [DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER]
                    },
                    "metrics": ["humidity"]
                })

        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }

    # === CHECK MODE ===
    item = params.get("item", "")
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        SNMP_BASE + OID_NAME,
        SNMP_BASE + OID_HUMIDITY
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpget failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output: each line is "OID = TYPE: value"
    lines = res.stdout.splitlines()
    name = ""
    humidity_val = -1

    for line in lines:
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if oid_part == SNMP_BASE + OID_NAME:
            if value_part.startswith("STRING: "):
                name = value_part[8:].strip().strip('"')
        elif oid_part == SNMP_BASE + OID_HUMIDITY:
            if value_part.startswith("INTEGER: "):
                humidity_val = _saveint(value_part[9:].strip())
            elif value_part.isdigit():
                humidity_val = int(value_part)

    # Check if the current item matches the discovered sensor name
    if item != "" and name != item:
        return {
            "changed": False,
            "msg": "no matching sensor found for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # If humidity < 0, sensor missing
    if humidity_val < 0:
        return {
            "changed": False,
            "msg": "humidity sensor not present or reading invalid",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply thresholds: levels=(warn, crit), levels_lower=(warn_lower, crit_lower)
    levels = params.get("levels", [DEFAULT_WARN, DEFAULT_CRIT])
    warn = levels[0]
    crit = levels[1]

    levels_lower = params.get("levels_lower", [DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER])
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]

    # State logic: upper and lower bounds
    state = "OK"
    if humidity_val >= crit:
        state = "CRIT"
    elif humidity_val >= warn:
        state = "WARN"
    elif humidity_val <= crit_lower:
        state = "CRIT"
    elif humidity_val <= warn_lower:
        state = "WARN"

    # Build message
    msg = "Humidity: %d%%" % humidity_val

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": float(humidity_val)},
            "details": ""
        }
    }
