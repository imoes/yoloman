# ===== Starlark check module for fjdarye_controller_modules_memory =====
# Reads controller module status via SNMP and reports OK/WARN/CRIT/UNKNOWN

# SNMP base OIDs per device type (from Checkmk source)
FJDARYE_DEVICE_OIDS = {
    ".1.3.6.1.4.1.211.1.21.1.60": ".2.3.2.1",   # fjdarye60
    ".1.3.6.1.4.1.211.1.21.1.100": ".2.4.2.1",  # fjdarye100
    ".1.3.6.1.4.1.211.1.21.1.101": ".2.4.2.1",  # fjdarye101
    ".1.3.6.1.4.1.211.1.21.1.150": ".2.4.2.1",  # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153": ".2.4.2.1",  # fjdarye600
}

# Status mapping: "1" -> OK, "2" -> CRIT, "3" -> WARN, "4" -> CRIT, "5" -> CRIT, "6" -> CRIT
FJDARYE_ITEM_STATUS = {
    "1": "OK",
    "2": "CRIT",
    "3": "WARN",
    "4": "CRIT",
    "5": "CRIT",
    "6": "CRIT",
}


def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        # Probe SNMP for controller module memory status
        # We try each base OID until one succeeds (only one device matches)
        res = None
        for device_oid, module_oid_suffix in FJDARYE_DEVICE_OIDS.items():
            base_oid = device_oid + module_oid_suffix + ".1"
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                base_oid
            ], mutates=False)
            if res.rc == 0 and res.stdout:
                break
            res = None

        if not res or not res.stdout:
            return {
                "changed": False,
                "msg": "no SNMP data found",
                "data": {"discovery": []}
            }

        # Parse snmpwalk output: lines like "<oid>.<index> = INTEGER: <status>"
        discovery = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Split on " = " to separate OID+index from value
            parts = line.rsplit(" = ", 1)
            if len(parts) != 2:
                continue
            value_part = parts[1]
            # Extract index from OID (last component after last dot)
            oid_part = parts[0]
            idx = oid_part.rsplit(".", 1)[-1] if "." in oid_part else ""
            # Extract status (INTEGER: <num>)
            if not value_part.startswith("INTEGER: "):
                continue
            status = value_part[9:].strip()
            # Skip invalid (status 4) per Checkmk source
            if status == "4":
                continue
            # Item is the index (string)
            discovery.append({
                "item": idx,
                "params": {},
                "metrics": []
            })

        return {
            "changed": False,
            "msg": "discovered %d controller modules" % len(discovery),
            "data": {"discovery": discovery}
        }

    # CHECK MODE
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Run snmpget for the specific item's status OID
    status_oid = None
    for device_oid, module_oid_suffix in FJDARYE_DEVICE_OIDS.items():
        base_oid = device_oid + module_oid_suffix + ".1"
        status_oid = base_oid + "." + str(item)
        break  # Only need one base to try (we don't know which device this host is)
    # But to be safe, try all bases until one works (same logic as discovery)
    res = None
    for device_oid, module_oid_suffix in FJDARYE_DEVICE_OIDS.items():
        base_oid = device_oid + module_oid_suffix + ".1"
        oid = base_oid + "." + str(item)
        res = ctx.run([
            "snmpget",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            oid
        ], mutates=False)
        if res.rc == 0 and res.stdout and "No such object" not in res.stdout:
            break
        res = None

    # No data found for item
    if not res or not res.stdout or "No such object" in res.stdout:
        return {
            "changed": False,
            "msg": "controller module %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse status value: "OID = INTEGER: <status>"
    line = res.stdout.strip()
    parts = line.rsplit(" = ", 1)
    if len(parts) != 2 or not parts[1].startswith("INTEGER: "):
        return {
            "changed": False,
            "msg": "invalid SNMP response for module %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status = parts[1][9:].strip()  # Strip "INTEGER: " prefix
    # Determine state
    state = FJDARYE_ITEM_STATUS.get(status, "UNKNOWN")
    summary = {
        "OK": "Normal",
        "WARN": "Warning",
        "CRIT": "Invalid or Alarm",
        "UNKNOWN": "Unknown status"
    }.get(state, "Unknown")

    return {
        "changed": False,
        "msg": "Module %s: %s" % (item, summary),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }