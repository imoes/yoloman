# ===== module-level constants =====
DATAPOWER_TEMP_OID_BASE = ".1.3.6.1.4.1.14685.3.1.141.1"
DATAPOWER_TEMP_STATUS_MAPPING = {
    "8": "CRIT device status: failure",
    "9": "UNKNOWN device status: noReading",
    "10": "CRIT device status: invalid",
}
DEFAULT_WARN = 65.0
DEFAULT_CRIT = 70.0


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), DATAPOWER_TEMP_OID_BASE
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }

        # Parse SNMP output: OID = TYPE: value lines
        entries = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid, value_part = parts
            # Extract instance index (last number after last dot)
            oid_parts = oid.split(".")
            if len(oid_parts) < 10:
                continue
            idx_str = oid_parts[-1]
            idx = int(idx_str) if idx_str.isdigit() else None
            if idx == None:
                continue
            value = value_part.split(": ", 1)
            if len(value) != 2:
                continue
            val_str = value[1].strip()

            # Group by index
            if idx not in entries:
                entries[idx] = {}
            entries[idx][oid_parts[-2]] = val_str

        # Reconstruct records: name, temp, warn, status, crit
        discovered = []
        for idx in entries:
            e = entries[idx]
            name_raw = e.get("1", "")
            temp_str = e.get("2", "")
            warn_str = e.get("3", "")
            status_str = e.get("5", "")
            crit_str = e.get("6", "")

            name = name_raw.strip("Temperature ")
            # Skip if name is empty or name_raw doesn't start with "Temperature "
            if not name or not name_raw.startswith("Temperature "):
                continue

            temp = float(temp_str) if temp_str.replace(".", "").replace("-", "").isdigit() else None
            warn = float(warn_str) if warn_str.replace(".", "").replace("-", "").isdigit() else None
            crit = float(crit_str) if crit_str.replace(".", "").replace("-", "").isdigit() else None

            # Use SNMP thresholds if present, otherwise defaults
            warn = warn if warn != None else DEFAULT_WARN
            crit = crit if crit != None else DEFAULT_CRIT

            status_msg = DATAPOWER_TEMP_STATUS_MAPPING.get(status_str, None)
            metrics = ["temperature"]

            discovered.append({
                "item": name,
                "params": {"levels": (warn, crit)},
                "metrics": metrics
            })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), DATAPOWER_TEMP_OID_BASE
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse and look for item
    entries = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid, value_part = parts
        oid_parts = oid.split(".")
        if len(oid_parts) < 10:
            continue
        idx_str = oid_parts[-1]
        idx = int(idx_str) if idx_str.isdigit() else None
        if idx == None:
            continue
        value = value_part.split(": ", 1)
        if len(value) != 2:
            continue
        val_str = value[1].strip()

        if idx not in entries:
            entries[idx] = {}
        entries[idx][oid_parts[-2]] = val_str

    # Find matching sensor
    found = False
    temp_val = None
    status_msg = None
    warn = DEFAULT_WARN
    crit = DEFAULT_CRIT

    for idx in entries:
        e = entries[idx]
        name_raw = e.get("1", "")
        temp_str = e.get("2", "")
        status_str = e.get("5", "")
        warn_str = e.get("3", "")
        crit_str = e.get("6", "")

        name = name_raw.strip("Temperature ")
        if not name or not name_raw.startswith("Temperature "):
            continue

        if name == item:
            found = True
            temp_val = float(temp_str) if temp_str.replace(".", "").replace("-", "").isdigit() else None
            if warn_str.replace(".", "").replace("-", "").isdigit():
                warn = float(warn_str)
            if crit_str.replace(".", "").replace("-", "").isdigit():
                crit = float(crit_str)
            status_msg = DATAPOWER_TEMP_STATUS_MAPPING.get(status_str, None)
            break

    # Device not found or item missing
    if not found or temp_val == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply thresholds
    levels = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))
    warn_threshold = levels[0] if levels[0] != None else DEFAULT_WARN
    crit_threshold = levels[1] if levels[1] != None else DEFAULT_CRIT

    state = "OK"
    if status_msg:
        if status_msg.startswith("CRIT"):
            state = "CRIT"
            msg = status_msg
        elif status_msg.startswith("UNKNOWN"):
            state = "UNKNOWN"
            msg = status_msg
        else:
            state = "OK"
            msg = "sensor status: ok"
    else:
        if temp_val >= crit_threshold:
            state = "CRIT"
        elif temp_val >= warn_threshold:
            state = "WARN"
        else:
            state = "OK"
        msg = "Temperature: %f C" % temp_val

    # Return result
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp_val},
            "details": ""
        }
    }
