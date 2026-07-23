def main(ctx, params):
    # Discoverable check: read temperature sensors via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode: enumerate all temperature sensors
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.5003.9.10.10.4.21.1.11"
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }

        # Parse snmpwalk output: "OID = INTEGER: value"
        sensors = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = INTEGER: ")
            if len(parts) == 2:
                # The OID end is the sensor index; use it as the item
                oid_end = parts[0].strip().rsplit(".", 1)[-1]
                sensors.append({
                    "item": oid_end,
                    "params": {},
                    "metrics": ["temp"]
                })
        msg = "discovered %d sensors" % len(sensors)
        return {"changed": False, "msg": msg, "data": {"discovery": sensors}}

    # Check mode: verify one specific sensor
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "item is required",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get temperature value for the specific sensor
    oid = ".1.3.6.1.4.1.5003.9.10.10.4.21.1.11." + item
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, oid
    ], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP get failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output: "OID = INTEGER: value"
    line = res.stdout.strip()
    parts = line.split(" = INTEGER: ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "malformed SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = parts[1].strip()
    if not value_str or (value_str.startswith("-") and not value_str[1:].isdigit()) or (not value_str.startswith("-") and not value_str.isdigit()):
        return {
            "changed": False,
            "msg": "invalid temperature value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    temp = int(value_str)

    # Handle special case: -1 means temperature is not available
    if temp == -1:
        return {
            "changed": False,
            "msg": "Temperature is not available",
            "data": {"state": "OK", "metrics": {"temp": -1}, "details": ""}
        }

    # Apply temperature thresholds
    warn = params.get("levels", (80.0, 90.0))  # (warn, crit) defaults
    warn_val = warn[0] if isinstance(warn, (list, tuple)) else warn
    crit_val = warn[1] if isinstance(warn, (list, tuple)) else warn

    if temp >= crit_val:
        state = "CRIT"
    elif temp >= warn_val:
        state = "WARN"
    else:
        state = "OK"

    # Format human-readable message
    msg = "Temperature: %f C" % temp
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": float(temp)},
            "details": ""
        }
    }
