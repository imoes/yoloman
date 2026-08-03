# Translated from Checkmk checkmk.fjdarye_controller_modules_flash.py
# Monitors Fujitsu storage systems (FJDARY-E60/E100 MIB) controller module flash status via SNMP.

def _snmp_get(ctx, oid, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _sys_descr_oid(ctx, community, host):
    # Fetch sysDescr.0 to inspect for Fujitsu storage signature
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _is_fjdarye(ctx, community, host):
    sys_oid = _sys_descr_oid(ctx, community, host)
    if sys_oid == None:
        return False
    # FJDARY supported devices
    supported = [
        ".1.3.6.1.4.1.211.1.21.1.60",
        ".1.3.6.1.4.1.211.1.21.1.150",
        ".1.3.6.1.4.1.211.1.21.1.153",
    ]
    return sys_oid in supported

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Check if this is a Fujitsu storage device
        if not _is_fjdarye(ctx, community, host):
            return {"changed": False, "msg": "not a FJDARY-E60/E100 device", "data": {"discovery": []}}

        # The table base is .2.4.2.1 under the device enterprise OID
        # We need to walk to find which device OID is present; try the supported device OIDs
        discovery = []
        found_items = []
        supported_bases = [
            ".1.3.6.1.4.1.211.1.21.1.60",
            ".1.3.6.1.4.1.211.1.21.1.150",
            ".1.3.6.1.4.1.211.1.21.1.153",
        ]

        for device_oid in supported_bases:
            table_base = device_oid + ".2.4.2.1"
            # Column 1: Index, Column 3: Status
            walk_oid = table_base + ".1"
            res = ctx.run(
                ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, walk_oid],
                mutates=False,
            )
            if res.rc != 0:
                continue
            lines = res.stdout.splitlines()
            for line in lines:
                parts = line.split(None, 1)
                if len(parts) < 2:
                    continue
                oid_full = parts[0]
                index_value = parts[1].strip()
                # The index in the OID is the suffix after the column OID
                # oid_full looks like <table_base>.1.<index>, we want the index
                # But the value here is the index value (column 1 = index)
                # Actually in FJDARY MIB, column 1 is the index, so the OID index part
                # is what follows .1 from the column OID
                suffix = oid_full[len(walk_oid) + 1:] if oid_full.startswith(walk_oid) else ""
                if not suffix:
                    continue
                # Use the index value as the item
                if suffix not in found_items:
                    found_items.append(suffix)
                    discovery.append({
                        "item": suffix,
                        "metrics": [],
                    })

        return {
            "changed": False,
            "msg": "discovered %d controller module flash items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE
    item = params.get("item", "")

    if not _is_fjdarye(ctx, community, host):
        return {
            "changed": False,
            "msg": "not a FJDARY-E60/E100 device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Find the correct device OID by checking which one responds
    supported_bases = [
        ".1.3.6.1.4.1.211.1.21.1.60",
        ".1.3.6.1.4.1.211.1.21.1.150",
        ".1.3.6.1.4.1.211.1.21.1.153",
    ]

    table_base = None
    for device_oid in supported_bases:
        candidate = device_oid + ".2.4.2.1"
        # Test if the index column (1) has our item
        test_oid = candidate + ".1." + item
        res = _snmp_get(ctx, test_oid, community, host)
        if res != None:
            table_base = candidate
            break

    if table_base == None:
        return {
            "changed": False,
            "msg": "item %s not found on any FJDARY device table" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch the status (column 3) for this item
    status_oid = table_base + ".3." + item
    status_raw = _snmp_get(ctx, status_oid, community, host)
    if status_raw == None:
        return {
            "changed": False,
            "msg": "unable to fetch flash status for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Strip potential quotes from the value
    status_value = status_raw.strip().strip('"').strip("'")

    # Map status codes (as per FJDARYE_ITEM_STATUS)
    status_map = {
        "1": {"summary": "Normal", "state": "OK"},
        "2": {"summary": "Alarm", "state": "CRIT"},
        "3": {"summary": "Warning", "state": "WARN"},
        "4": {"summary": "Invalid", "state": "CRIT"},
        "5": {"summary": "Maintenance", "state": "CRIT"},
        "6": {"summary": "Undefined", "state": "CRIT"},
    }

    entry = status_map.get(status_value)
    if entry == None:
        return {
            "changed": False,
            "msg": "Unknown status code %s for item %s" % (status_value, item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": entry["summary"],
        "data": {
            "state": entry["state"],
            "metrics": {},
            "details": "",
        },
    }