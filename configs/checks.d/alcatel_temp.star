def main(ctx, params):
    # === module-level constants ===
    OID_BASE = ".1.3.6.1.4.1.6486.800.1.1.1.3.1.1.3.1"
    OID_BOARD = "4"
    OID_CPU = "5"
    DEFAULT_WARN = 45.0
    DEFAULT_CRIT = 50.0

    # === discovery mode ===
    if params.get("_discover"):
        # Fetch both Board and CPU temperature OIDs for all slots
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            OID_BASE + "." + OID_BOARD, OID_BASE + "." + OID_CPU
        ], mutates=False)

        # Parse snmpwalk output: lines like "<oid>.<index> = INTEGER: <value>"
        lines = res.stdout.splitlines()
        # Group by OID type (board vs cpu)
        board_temps = {}
        cpu_temps = {}

        idx = 0
        while idx < len(lines):
            line = lines[idx]
            if not line.strip():
                idx = idx + 1
                continue
            # Split on '=' and clean up
            parts = line.strip().split("=", 1)
            if len(parts) != 2:
                idx = idx + 1
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract index and value
            # OID ends with .<oid_index>
            oid_leaf = oid_part.rsplit(".", 1)
            if len(oid_leaf) != 2:
                idx = idx + 1
                continue
            index_str = oid_leaf[1]
            value = value_part
            # Value should be "INTEGER: <int>" or just "<int>"
            if value.startswith("INTEGER: "):
                value = value[len("INTEGER: "):]
            # Guard: ensure value is integer-like
            temp_val = int(value) if value.isdigit() else 0
            oid_name = oid_leaf[0].rsplit(".", 1)[1]
            if oid_name == OID_BOARD:
                board_temps[index_str] = temp_val
            elif oid_name == OID_CPU:
                cpu_temps[index_str] = temp_val
            idx = idx + 1

        # Determine number of slots (max index in either dict, 1-indexed)
        all_indices = board_temps.keys() + cpu_temps.keys()
        if not all_indices:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        # Find max slot index (they are 1-based, so use max+1 or max if 1..N)
        max_idx = 0
        for k in all_indices:
            v = int(k)
            if v > max_idx:
                max_idx = v
        num_slots = max_idx

        # Build discovery list
        discovery = []
        slot = 1
        while slot <= num_slots:
            # Check if both temps are non-zero
            board_val = board_temps.get(str(slot), 0)
            cpu_val = cpu_temps.get(str(slot), 0)
            if board_val != 0:
                discovery.append({
                    "item": "Slot %d Board" % slot,
                    "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                    "metrics": ["temp"]
                })
            if cpu_val != 0:
                discovery.append({
                    "item": "Slot %d CPU" % slot,
                    "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                    "metrics": ["temp"]
                })
            slot = slot + 1
        if not discovery:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # === check mode (single item) ===
    item = params.get("item", "")

    # Parse item: either "Slot N Board/CPU" or "Board/CPU"
    slot = 1
    sensor = ""
    if item.startswith("Slot "):
        parts = item.split()
        if len(parts) < 3:
            return {"changed": False, "msg": "invalid item format: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        slot_str = parts[1]
        if not slot_str.isdigit():
            return {"changed": False, "msg": "invalid slot number in item: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        slot = int(slot_str)
        sensor = parts[2]
    else:
        sensor = item

    if sensor not in ["Board", "CPU"]:
        return {"changed": False, "msg": "unsupported sensor: " + sensor,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build OID leaf: .<OID> where OID is 4 or 5, index is slot (1-based)
    oid_num = OID_BOARD if sensor == "Board" else OID_CPU
    full_oid = OID_BASE + "." + oid_num + "." + str(slot)

    # Fetch just this OID
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), full_oid
    ], mutates=False)

    # Parse snmpget output: "<oid> = INTEGER: <value>"
    output = res.stdout.strip()
    if not output or "No such variable" in output or "Cannot get value" in output:
        return {"changed": False, "msg": "sensor not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract value
    value_part = ""
    if output.count("=") == 1:
        value_part = output.split("=", 1)[1].strip()
    if value_part.startswith("INTEGER: "):
        value_part = value_part[len("INTEGER: "):]

    # Guard: ensure value is integer-like
    if not value_part.isdigit():
        return {"changed": False, "msg": "could not parse temperature",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_celsius = float(value_part)

    # Apply temperature thresholds
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)

    state = "OK"
    if temp_celsius >= crit:
        state = "CRIT"
    elif temp_celsius >= warn:
        state = "WARN"

    msg = "%s: %f C" % (item, temp_celsius)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": temp_celsius},
            "details": ""
        }
    }
