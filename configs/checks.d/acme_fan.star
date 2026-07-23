def main(ctx, params):
    # State mapping from Checkmk's ACME_ENVIRONMENT_STATES
    STATE_MAP = {
        "1": ("OK", "initial"),
        "2": ("OK", "normal"),
        "3": ("WARN", "minor"),
        "4": ("WARN", "major"),
        "5": ("CRIT", "critical"),
        "6": ("CRIT", "shutdown"),
        "7": ("CRIT", "not present"),
        "8": ("CRIT", "not functioning"),
        "9": ("CRIT", "unknown"),
    }

    # Discover mode
    if params.get("_discover"):
        # Get snmpwalk data for acme_fan section
        base_oid = ".1.3.6.1.4.1.9148.3.3.1.4.1.1"
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            base_oid
        ], mutates=False)

        # Parse OID output lines
        fans = []
        # Maps for quick lookup:descr -> (value, state) by extracting index
        descr_map = {}
        value_map = {}
        state_map = {}

        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, val_part = parts
            # Extract value type and string
            val_type, val_str = val_part.split(": ", 1)
            val_str = val_str.strip()

            # Parse OID to get index
            # Base part: .1.3.6.1.4.1.9148.3.3.1.4.1.1.
            base_part = ".1.3.6.1.4.1.9148.3.3.1.4.1.1."
            if not oid_full.startswith(base_part):
                continue
            suffix = oid_full[len(base_part):]
            dot_idx = suffix.find(".")
            if dot_idx == -1:
                continue
            oid_type = suffix[:dot_idx].strip()
            idx = suffix[dot_idx + 1:].strip()
            if not idx.isdigit():
                continue

            if oid_type == "3":  # description
                descr_map[idx] = val_str
            elif oid_type == "4":  # value (fan speed)
                value_map[idx] = val_str
            elif oid_type == "5":  # state
                state_map[idx] = val_str

        # Build fan list
        for idx in descr_map:
            if idx in state_map and state_map[idx] != "7":
                fans.append({
                    "item": descr_map[idx],
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d fans" % len(fans),
            "data": {"discovery": fans}
        }

    # Check mode (non-discovery)
    item = params.get("item", "")
    # Reuse the same SNMP query for check
    base_oid = ".1.3.6.1.4.1.9148.3.3.1.4.1.1"
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        base_oid
    ], mutates=False)

    # Parse for the requested item
    # First, map index->descr and then find the matching item
    descr_map = {}
    value_map = {}
    state_map = {}

    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, val_part = parts
        val_type, val_str = val_part.split(": ", 1)
        val_str = val_str.strip()

        base_part = ".1.3.6.1.4.1.9148.3.3.1.4.1.1."
        if not oid_full.startswith(base_part):
            continue
        suffix = oid_full[len(base_part):]
        dot_idx = suffix.find(".")
        if dot_idx == -1:
            continue
        oid_type = suffix[:dot_idx].strip()
        idx = suffix[dot_idx + 1:].strip()
        if not idx.isdigit():
            continue

        if oid_type == "3":
            descr_map[idx] = val_str
        elif oid_type == "4":
            value_map[idx] = val_str
        elif oid_type == "5":
            state_map[idx] = val_str

    # Find index matching the item name
    idx_found = None
    for idx in descr_map:
        if descr_map[idx] == item:
            idx_found = idx
            break

    if idx_found == None or idx_found not in state_map:
        return {
            "changed": False,
            "msg": "fan not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state_val = state_map[idx_found]
    value_str = value_map.get(idx_found, "0")

    if state_val in STATE_MAP:
        dev_state, dev_state_readable = STATE_MAP[state_val]
    else:
        dev_state = "UNKNOWN"
        dev_state_readable = "unknown (%s)" % state_val

    speed = int(value_str) if value_str.isdigit() else 0

    return {
        "changed": False,
        "msg": "Status: %s, Speed: %s%%" % (dev_state_readable, value_str),
        "data": {
            "state": dev_state,
            "metrics": {"speed": speed},
            "details": ""
        }
    }