def main(ctx, params):
    # Constants for SNMP OID
    BASE_OID = ".1.3.6.1.4.1.3417.2.4.1.1.1"
    OID_NAME = BASE_OID + ".3"
    OID_READING = BASE_OID + ".4"
    OID_STATUS = BASE_OID + ".6"

    if params.get("_discover"):
        # Discovery: walk all three OIDs together
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            OID_NAME, OID_READING, OID_STATUS
        ], mutates=False)

        # Parse snmpwalk output: each line is "<oid>.<index> = STRING: value"
        lines = res.stdout.splitlines()
        entries = {}
        for line in lines:
            if not line:
                continue
            parts = line.split(" = ", 2)
            if len(parts) < 2:
                continue
            oid_with_index = parts[0].strip()
            value = parts[1].strip()

            if not oid_with_index.startswith(BASE_OID):
                continue
            suffix = oid_with_index[len(BASE_OID):]
            if not suffix.startswith("."):
                continue
            idx_str = suffix[1:]
            if not idx_str.isdigit():
                continue
            idx = idx_str

            if not idx in entries:
                entries[idx] = {"name": "", "reading": 0.0, "status": ""}

            if oid_with_index == OID_NAME + "." + idx:
                entries[idx]["name"] = value.strip('"')
            elif oid_with_index == OID_READING + "." + idx:
                entries[idx]["reading"] = float(value) if value.replace(".", "", 1).isdigit() or (value.startswith("-") and value[1:].replace(".", "", 1).isdigit()) else 0.0
            elif oid_with_index == OID_STATUS + "." + idx:
                entries[idx]["status"] = value

        discovered = []
        for idx, entry in entries.items():
            name = entry.get("name", "")
            if not name:
                continue
            discovered.append({
                "item": name,
                "params": {},
                "metrics": ["value"]
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode
    item = params.get("item", "")

    # Walk SNMP data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        OID_NAME, OID_READING, OID_STATUS
    ], mutates=False)

    lines = res.stdout.splitlines()
    entries = {}
    for line in lines:
        if not line:
            continue
        parts = line.split(" = ", 2)
        if len(parts) < 2:
            continue
        oid_with_index = parts[0].strip()
        value = parts[1].strip()

        if not oid_with_index.startswith(BASE_OID):
            continue
        suffix = oid_with_index[len(BASE_OID):]
        if not suffix.startswith("."):
            continue
        idx_str = suffix[1:]
        if not idx_str.isdigit():
            continue
        idx = idx_str

        if not idx in entries:
            entries[idx] = {"name": "", "reading": 0.0, "status": ""}

        if oid_with_index == OID_NAME + "." + idx:
            entries[idx]["name"] = value.strip('"')
        elif oid_with_index == OID_READING + "." + idx:
            entries[idx]["reading"] = float(value) if value.replace(".", "", 1).isdigit() or (value.startswith("-") and value[1:].replace(".", "", 1).isdigit()) else 0.0
        elif oid_with_index == OID_STATUS + "." + idx:
            entries[idx]["status"] = value

    cpu = None
    for idx, entry in entries.items():
        if entry.get("name") == item:
            cpu = entry
            break

    if cpu == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    reading = cpu.get("reading", 0.0)
    status = cpu.get("status", "")
    is_ok = status == "1"
    state = "OK" if is_ok else "CRIT"

    # Round without round(): int(x + 0.5)
    rounded_reading = int(reading + 0.5)

    return {
        "changed": False,
        "msg": "%d%%" % rounded_reading,
        "data": {
            "state": state,
            "metrics": {"value": reading},
            "details": ""
        }
    }