# ===== Starlark check module: checkpoint_fan =====
# Reproduces checkmk.checkpoint_fan: SNMP-based fan sensor monitor

# SNMP OID constants
BASE_OID = ".1.3.6.1.4.1.2620.1.6.7.8.2.1"
OID_NAME = BASE_OID + ".2"
OID_VALUE = BASE_OID + ".3"
OID_UNIT = BASE_OID + ".4"
OID_DEV_STATUS = BASE_OID + ".6"

# Detection OIDs
SYSOID = ".1.3.6.1.2.1.1.2.0"
SYSDESCR = ".1.3.6.1.2.1.1.1.0"
DETECT_OID_1 = ".1.3.6.1.4.1.2620.1.1.21.0"
DETECT_OID_2 = ".1.3.6.1.4.1.2620.1.6.5.1.0"

# Status mapping: "0" -> OK, "1" -> CRIT, "2" -> UNKNOWN
SENSOR_STATUS_TO_CMK_STATUS = {
    "0": ("OK", "sensor in range"),
    "1": ("CRIT", "sensor out of range"),
    "2": ("UNKNOWN", "reading error"),
}

def main(ctx, params):
    if params.get("_discover"):
        # Discover fans via SNMP
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            OID_NAME
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}

        out = []
        for line in res.stdout.splitlines():
            # Format: OID = STRING: "name Fan"
            if " = " not in line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            value = parts[1].strip()
            # Strip quotes if present
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            # Check if it ends with " Fan"
            if value.endswith(" Fan"):
                item = value.replace(" Fan", "")
                out.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })
        return {"changed": False, "msg": "discovered %d fans" % len(out),
                "data": {"discovery": out}}

    # Check mode: inspect one item
    item = params.get("item", "")
    # First check detection (must be a Check Point device)
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        SYSOID
    ], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "SNMP check failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sysoid_value = ""
    for line in res.stdout.splitlines():
        if " = " in line:
            sysoid_value = line.split(" = ")[1].strip()
            break

    # Detect logic: must match Check Point patterns
    is_checkpoint = (
        sysoid_value.startswith(".1.3.6.1.4.1.2620") or
        "cp " in sysoid_value or
        sysoid_value.startswith("IPSO ") or
        "Linux" in sysoid_value and "cpx" in sysoid_value
    )

    if not is_checkpoint:
        # Not a Check Point device - no services
        return {"changed": False, "msg": "not a Check Point device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get value, unit, dev_status for this item
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        OID_NAME
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build item -> (value, unit, dev_status) map
    fan_data = {}
    name_lines = res.stdout.splitlines()
    for line in name_lines:
        if " = " not in line or "STRING: " not in line:
            continue
        oid_part, value_part = line.split(" = ", 1)
        name = value_part.strip().strip('"')
        if not name.endswith(" Fan"):
            continue
        item_name = name.replace(" Fan", "")
        fan_data[item_name] = {"name": name}

    # Fetch value, unit, dev_status in one walk for each OID
    for (oid, key) in [(OID_VALUE, "value"), (OID_UNIT, "unit"), (OID_DEV_STATUS, "dev_status")]:
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            oid
        ], mutates=False)
        if res.rc != 0:
            continue
        lines = res.stdout.splitlines()
        idx = 0
        for line in lines:
            if " = " not in line:
                continue
            oid_part, value_part = line.split(" = ", 1)
            # Get next OID part index
            if idx < len(fan_data):
                item_key = list(fan_data.keys())[idx]
                fan_data[item_key][key] = value_part.strip().strip('"')
            idx += 1

    # Look up requested item
    found = False
    for item_name in fan_data:
        if item_name == item:
            found = True
            data = fan_data[item_name]
            dev_status = data.get("dev_status", "")
            value = data.get("value", "0")
            unit = data.get("unit", "")

            if dev_status in SENSOR_STATUS_TO_CMK_STATUS:
                state, state_readable = SENSOR_STATUS_TO_CMK_STATUS[dev_status]
                summary = "Status: %s, %s %s" % (state_readable, value, unit)
            else:
                state = "UNKNOWN"
                summary = "Status: unknown (%s), %s %s" % (dev_status, value, unit)

            return {"changed": False, "msg": summary,
                    "data": {"state": state, "metrics": {}, "details": ""}}

    if not found:
        return {"changed": False, "msg": "fan item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fallback
    return {"changed": False, "msg": "no data for item",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
