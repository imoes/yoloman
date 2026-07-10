def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9148.3.3.1.4.1.1"],
            mutates=False
        )
        # Parse SNMP output: we need three consecutive OIDs per fan:
        # .1.3.6.1.4.1.9148.3.3.1.4.1.1.3.<n> -> description
        # .1.3.6.1.4.1.9148.3.3.1.4.1.1.4.<n> -> value (speed %)
        # .1.3.6.1.4.1.9148.3.3.1.4.1.1.5.<n> -> state
        fans = {}  # index -> {"descr": ..., "value": ..., "state": ...}
        lines = res.stdout.splitlines()
        for line in lines:
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            oid_part = oid_part.strip()
            value_part = value_part.strip()
            # Extract value: handle STRING:, INTEGER:, etc.
            if ":" in value_part:
                value_str = value_part.split(":", 1)[1].strip().strip('"')
            else:
                value_str = value_part
            # Check OID suffix
            # Descriptions end with .3.index
            if oid_part.endswith(".3.1") or oid_part.endswith(".3.2") or oid_part.endswith(".3.3") or oid_part.endswith(".3.4"):
                idx = oid_part.rsplit(".", 1)[1]
                fans.setdefault(idx, {})["descr"] = value_str
            elif oid_part.endswith(".4.1") or oid_part.endswith(".4.2") or oid_part.endswith(".4.3") or oid_part.endswith(".4.4"):
                idx = oid_part.rsplit(".", 1)[1]
                fans.setdefault(idx, {})["value"] = value_str
            elif oid_part.endswith(".5.1") or oid_part.endswith(".5.2") or oid_part.endswith(".5.3") or oid_part.endswith(".5.4"):
                idx = oid_part.rsplit(".", 1)[1]
                fans.setdefault(idx, {})["state"] = value_str

        discovery_list = []
        for idx, data in fans.items():
            state = data.get("state", "7")
            # Skip fans with state "7" (not present)
            if state == "7":
                continue
            item = data.get("descr", "Fan " + idx)
            discovery_list.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }

    # CHECK MODE
    item = params.get("item", "")
    res = ctx.run(
        ["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9148.3.3.1.4.1.1.3.1", ".1.3.6.1.4.1.9148.3.3.1.4.1.1.4.1", ".1.3.6.1.4.1.9148.3.3.1.4.1.1.5.1",
         ".1.3.6.1.4.1.9148.3.3.1.4.1.1.3.2", ".1.3.6.1.4.1.9148.3.3.1.4.1.1.4.2", ".1.3.6.1.4.1.9148.3.3.1.4.1.1.5.2",
         ".1.3.6.1.4.1.9148.3.3.1.4.1.1.3.3", ".1.3.6.1.4.1.9148.3.3.1.4.1.1.4.3", ".1.3.6.1.4.1.9148.3.3.1.4.1.1.5.3",
         ".1.3.6.1.4.1.9148.3.3.1.4.1.1.3.4", ".1.3.6.1.4.1.9148.3.3.1.4.1.1.4.4", ".1.3.6.1.4.1.9148.3.3.1.4.1.1.5.4"],
        mutates=False
    )
    # Build lookup: key = item description
    section = {}
    lines = res.stdout.splitlines()
    # Group in sets of three: descr, value, state per fan index
    # But snmpget returns lines in arbitrary order per OID; better parse by OID suffix index
    fans_data = {}  # index -> {"descr": ..., "value": ..., "state": ...}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        oid_part = oid_part.strip()
        value_part = value_part.strip()
        # Extract value: handle STRING:, INTEGER:, etc.
        if ":" in value_part:
            value_str = value_part.split(":", 1)[1].strip().strip('"')
        else:
            value_str = value_part
        # Determine index
        if oid_part.endswith(".3.1"):
            fans_data.setdefault("1", {})["descr"] = value_str
        elif oid_part.endswith(".4.1"):
            fans_data.setdefault("1", {})["value"] = value_str
        elif oid_part.endswith(".5.1"):
            fans_data.setdefault("1", {})["state"] = value_str
        elif oid_part.endswith(".3.2"):
            fans_data.setdefault("2", {})["descr"] = value_str
        elif oid_part.endswith(".4.2"):
            fans_data.setdefault("2", {})["value"] = value_str
        elif oid_part.endswith(".5.2"):
            fans_data.setdefault("2", {})["state"] = value_str
        elif oid_part.endswith(".3.3"):
            fans_data.setdefault("3", {})["descr"] = value_str
        elif oid_part.endswith(".4.3"):
            fans_data.setdefault("3", {})["value"] = value_str
        elif oid_part.endswith(".5.3"):
            fans_data.setdefault("3", {})["state"] = value_str
        elif oid_part.endswith(".3.4"):
            fans_data.setdefault("4", {})["descr"] = value_str
        elif oid_part.endswith(".4.4"):
            fans_data.setdefault("4", {})["value"] = value_str
        elif oid_part.endswith(".5.4"):
            fans_data.setdefault("4", {})["state"] = value_str

    # Build section dict keyed by item (description)
    for idx, data in fans_data.items():
        descr = data.get("descr", "")
        state = data.get("state", "7")
        value_str = data.get("value", "0")
        section[descr] = (value_str, state)

    # Now look up the requested item
    if item not in section:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str, state = section[item]
    # Map state codes to Checkmk states as per library
    state_map = {
        "1": ("OK", "initial"),
        "2": ("OK", "normal"),
        "3": ("WARN", "minor"),
        "4": ("WARN", "major"),
        "5": ("CRIT", "critical"),
        "6": ("CRIT", "shutdown"),
        "7": ("CRIT", "not present"),
        "8": ("CRIT", "not functioning"),
        "9": ("CRIT", "unknown")
    }
    dev_state_str, dev_state_readable = state_map.get(state, ("UNKNOWN", "unknown"))
    if dev_state_str == "OK":
        dev_state = "OK"
    elif dev_state_str == "WARN":
        dev_state = "WARN"
    elif dev_state_str == "CRIT":
        dev_state = "CRIT"
    else:
        dev_state = "UNKNOWN"

    return {
        "changed": False,
        "msg": "Status: %s, Speed: %s%%" % (dev_state_readable, value_str),
        "data": {
            "state": dev_state,
            "metrics": {},
            "details": ""
        }
    }
