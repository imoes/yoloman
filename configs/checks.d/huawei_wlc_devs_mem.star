def main(ctx, params):
    # SNMP base and OIDs for huawei_wlc_devs section
    base_oid = ".1.3.6.1.4.1.2011.5.25.31.1.1"
    oid_mem_base = ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1.7"  # mem_used_percent
    oid_name_base = ".1.3.6.1.4.1.2011.5.25.31.1.1.2.1.13"  # device name

    # Determine community and host (common SNMP parameters)
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discovery mode: walk all devices and report memory items
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            oid_mem_base
        ], mutates=False)

        # Parse memory values and collect indices
        mem_values = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if oid_mem_base + "." not in line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            val = parts[1].strip()
            if not val.startswith("INTEGER: "):
                continue
            val_str = val.split("INTEGER: ", 1)[1]
            # Guard instead of try/except
            val_clean = val_str.strip()
            is_valid = val_clean.replace(".", "", 1).lstrip("-").isdigit() if val_clean else False
            if is_valid:
                mem_val = float(val_clean)
                # Extract index from OID tail
                oid_full = parts[0].strip()
                tail = oid_full.rsplit(".", 1)[-1]
                if tail.isdigit():
                    mem_values[tail] = mem_val

        # Now get names for these indices
        discovery_list = []
        for idx, mem_val in mem_values.items():
            name_oid_full = oid_name_base + "." + idx
            name_res = ctx.run([
                "snmpget", "-v2c", "-c", community, "-On", host, name_oid_full
            ], mutates=False)
            if name_res.rc != 0 or not name_res.stdout.strip():
                continue
            name_line = name_res.stdout.strip()
            name_parts = name_line.split(" = ", 1)
            if len(name_parts) != 2:
                continue
            name_val = name_parts[1].strip()
            if not name_val.startswith("STRING: "):
                continue
            name_str = name_val[8:].strip().strip('"')
            if name_str:
                discovery_list.append({
                    "item": name_str,
                    "params": {"levels": (80.0, 90.0)},
                    "metrics": ["mem_used_percent"]
                })

        return {
            "changed": False,
            "msg": "discovered %d devices" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }

    # Check mode: examine one item
    item = params.get("item", "")
    levels = params.get("levels", (80.0, 90.0))
    warn, crit = levels[0], levels[1]

    # Find index for this device by walking name OID
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        oid_name_base
    ], mutates=False)

    item_index = ""
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if oid_name_base + "." not in line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        val = parts[1].strip()
        if not val.startswith("STRING: "):
            continue
        name_str = val[8:].strip().strip('"')
        if name_str == item:
            oid_full = parts[0].strip()
            item_index = oid_full.rsplit(".", 1)[-1]
            break

    if item_index == "":
        return {
            "changed": False,
            "msg": "device not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get memory value for this index
    mem_oid_full = oid_mem_base + "." + item_index
    mem_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, mem_oid_full
    ], mutates=False)

    if mem_res.rc != 0 or not mem_res.stdout.strip():
        return {
            "changed": False,
            "msg": "failed to retrieve memory for device " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    mem_line = mem_res.stdout.strip()
    mem_parts = mem_line.split(" = ", 1)
    if len(mem_parts) != 2:
        return {
            "changed": False,
            "msg": "malformed memory response for device " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    mem_val_str = mem_parts[1].strip()
    if not mem_val_str.startswith("INTEGER: "):
        return {
            "changed": False,
            "msg": "unexpected memory format for device " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    mem_val_part = mem_val_str.split("INTEGER: ", 1)[1]
    # Guard instead of try/except
    val_clean = mem_val_part.strip()
    is_valid = val_clean.replace(".", "", 1).lstrip("-").isdigit() if val_clean else False
    mem_percent = float(val_clean) if is_valid else -1.0

    if mem_percent < 0:
        return {
            "changed": False,
            "msg": "invalid memory value for device " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine state based on levels (upper bounds)
    state = "OK"
    if mem_percent >= crit:
        state = "CRIT"
    elif mem_percent >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Used: %f%%" % mem_percent,
        "data": {
            "state": state,
            "metrics": {"mem_used_percent": mem_percent},
            "details": ""
        }
    }