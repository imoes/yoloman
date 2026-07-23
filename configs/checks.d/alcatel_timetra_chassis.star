def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.6527.3.1.2.2.1.8.1.8"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        # Parse snmpwalk output: "<oid> = STRING: <value>"
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 2)
            if len(parts) < 2:
                continue
            value = parts[1].strip()
            # Extract item name (value is typically like "String: chassis-1")
            if value.startswith("String: "):
                item = value[8:].strip().strip('"')
            else:
                item = value.strip().strip('"')
            if not item:
                continue
            # Need to check operstate to filter: only "2" or "8"
            # Fetch operstate OID: .1.3.6.1.4.1.6527.3.1.2.2.1.8.1.16
            # Build OID for this instance: append the index from the walk
            base_oid = ".1.3.6.1.4.1.6527.3.1.2.2.1.8.1.16"
            # Extract index from original OID (e.g., ...1.8.1.8.1 -> index "1")
            original_oid = parts[0].strip()
            # Original: .1.3.6.1.4.1.6527.3.1.2.2.1.8.1.8.<index>
            # Find last dot to get index
            last_dot = original_oid.rfind(".")
            if last_dot == -1:
                continue
            idx = original_oid[last_dot + 1:]
            oper_oid = base_oid + "." + idx
            res2 = ctx.run([
                "snmpget", "-v2c", "-c", community, "-On",
                host, oper_oid
            ], mutates=False)
            if res2.rc != 0 or not res2.stdout.strip():
                continue
            # Format: "<oid> = INTEGER: <value>"
            oper_parts = res2.stdout.strip().split(" = ", 2)
            if len(oper_parts) < 2:
                continue
            oper_value = oper_parts[1].strip()
            if not oper_value.startswith("INTEGER: "):
                continue
            oper_state = oper_value[9:].strip()
            # Only include if operstate is "2" (in service) or "8" (provisioned)
            if oper_state in ["2", "8"]:
                items.append({"item": item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d devices" % len(items),
            "data": {"discovery": items},
        }

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Build the base OID for this item's data
    # Need to get the index by walking the name OID and matching item
    # Fetch name OID: .1.3.6.1.4.1.6527.3.1.2.2.1.8.1.8
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.6527.3.1.2.2.1.8.1.8"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Find the index corresponding to the item
    target_idx = None
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 2)
        if len(parts) < 2:
            continue
        value = parts[1].strip()
        # Extract name (value is typically like "String: chassis-1")
        name = value[8:].strip().strip('"') if value.startswith("String: ") else value.strip().strip('"')
        if name == item:
            # Extract index from OID
            original_oid = parts[0].strip()
            last_dot = original_oid.rfind(".")
            if last_dot == -1:
                continue
            target_idx = original_oid[last_dot + 1:]
            break

    if target_idx == None:
        return {
            "changed": False,
            "msg": "device not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch adminstate (.1.3.6.1.4.1.6527.3.1.2.2.1.8.1.15), operstate (.1.3.6.1.4.1.6527.3.1.2.2.1.8.1.16), alarmstate (.1.3.6.1.4.1.6527.3.1.2.2.1.8.1.24)
    base_oid = ".1.3.6.1.4.1.6527.3.1.2.2.1.8.1"
    admin_oid = base_oid + ".15." + target_idx
    oper_oid = base_oid + ".16." + target_idx
    alarm_oid = base_oid + ".24." + target_idx

    admin_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, admin_oid], mutates=False)
    oper_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oper_oid], mutates=False)
    alarm_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, alarm_oid], mutates=False)

    # Parse values
    def get_int_value(res):
        if res.rc != 0 or not res.stdout.strip():
            return None
        parts = res.stdout.strip().split(" = ", 2)
        if len(parts) < 2:
            return None
        value = parts[1].strip()
        if value.startswith("INTEGER: "):
            val = value[9:].strip()
            return int(val) if val.isdigit() else None
        elif value.startswith("String: "):
            # For some reason it might be string; try parse
            val = value[8:].strip().strip('"')
            return int(val) if val.isdigit() else None
        elif value.isdigit():
            return int(value)
        return None

    admin_state = get_int_value(admin_res)
    oper_state = get_int_value(oper_res)
    alarm_state = get_int_value(alarm_res)

    # If any value == None, return UNKNOWN
    if admin_state == None or oper_state == None or alarm_state == None:
        return {
            "changed": False,
            "msg": "could not retrieve device state",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    admin_states = {
        1: (0, "noop"),
        2: (0, "in service"),
        3: (1, "out of service"),
        4: (2, "diagnose"),
        5: (2, "operate switch"),
    }
    oper_states = {
        1: (3, "unknown"),
        2: (0, "in service"),
        3: (2, "out of service"),
        4: (1, "diagnosing"),
        5: (2, "failed"),
        6: (1, "booting"),
        7: (3, "empty"),
        8: (0, "provisioned"),
        9: (3, "unprovisioned"),
        10: (1, "upgrade"),
        11: (1, "downgrade"),
        12: (1, "in service upgrade"),
        13: (1, "in service downgrade"),
        14: (1, "reset pending"),
    }
    alarm_states = {
        0: (0, "unknown"),
        1: (2, "alarm active"),
        2: (0, "alarm cleared"),
    }

    # Determine state
    # Priority: CRIT > WARN > UNKNOWN > OK
    state_codes = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    max_state = 0
    details_parts = []

    admin_tuple = admin_states.get(admin_state, (3, "unknown"))
    oper_tuple = oper_states.get(oper_state, (3, "unknown"))
    alarm_tuple = alarm_states.get(alarm_state, (0, "unknown"))

    # Admin state comparison with oper state
    if admin_state != oper_state:
        max_state = max(max_state, admin_tuple[0])
        details_parts.append("Admin state: " + admin_tuple[1])
    max_state = max(max_state, oper_tuple[0])
    details_parts.append("Operational state: " + oper_tuple[1])
    max_state = max(max_state, alarm_tuple[0])
    details_parts.append("Alarm state: " + alarm_tuple[1])

    # Build message (checkmk-style summary)
    msg = item + ": " + oper_tuple[1]
    if admin_state != oper_state:
        msg += " (admin: " + admin_tuple[1] + ")"
    if alarm_tuple[0] != 0:
        msg += ", alarm: " + alarm_tuple[1]

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_codes[max_state],
            "metrics": {},
            "details": "; ".join(details_parts),
        },
    }
