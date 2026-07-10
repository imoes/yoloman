def main(ctx, params):
    if params.get("_discover"):
        # Discover temperature sensors by polling the ACME SNMP MIB
        # OIDs: .1.3.6.1.4.1.9148.3.3.1.3.1.1.3.* (descr), .1.3.6.1.4.1.9148.3.3.1.3.1.1.4.* (value), .1.3.6.1.4.1.9148.3.3.1.3.1.1.5.* (state)
        res_descr = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9148.3.3.1.3.1.1.3"], mutates=False)
        res_value = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9148.3.3.1.3.1.1.4"], mutates=False)
        res_state = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9148.3.3.1.3.1.1.5"], mutates=False)

        if res_descr.rc != 0 or res_value.rc != 0 or res_state.rc != 0:
            return {"changed": False, "msg": "SNMP query failed", "data": {"discovery": []}}

        # Parse description entries: .1.3.6.1.4.1.9148.3.3.1.3.1.1.3.1 = "CPU TEMP0"
        def parse_snmpwalk_table(output, oid_base):
            entries = []
            for line in output.splitlines():
                if not line:
                    continue
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_str = parts[0].strip()
                if not oid_str.startswith(oid_base + "."):
                    continue
                suffix = oid_str.rsplit(".", 1)[1]
                # Check if suffix is a number
                if not suffix.isdigit():
                    continue
                idx = int(suffix)
                value = parts[1].strip().strip('"')
                entries.append((idx, value))
            return entries

        descrs = parse_snmpwalk_table(res_descr.stdout, ".1.3.6.1.4.1.9148.3.3.1.3.1.1.3")
        values = parse_snmpwalk_table(res_value.stdout, ".1.3.6.1.4.1.9148.3.3.1.3.1.1.4")
        states = parse_snmpwalk_table(res_state.stdout, ".1.3.6.1.4.1.9148.3.3.1.3.1.1.5")

        # Align by index
        descr_by_idx = {}
        for (idx, value) in descrs:
            descr_by_idx[idx] = value

        value_by_idx = {}
        for (idx, value) in values:
            value_by_idx[idx] = value

        state_by_idx = {}
        for (idx, value) in states:
            state_by_idx[idx] = value

        items = []
        for idx in descr_by_idx:
            if idx in value_by_idx and idx in state_by_idx:
                descr = descr_by_idx[idx]
                state = state_by_idx[idx]
                # Skip "not present" (state 7) as per discovery logic
                if state != "7":
                    items.append({"item": descr, "params": {}, "metrics": ["acme_temp.%s" % descr]})

        return {"changed": False, "msg": "discovered %d temperature sensors" % len(items),
                "data": {"discovery": items}}

    # Check mode: examine one temperature sensor item
    item = params.get("item", "")
    warn = params.get("warn", None)
    crit = params.get("crit", None)
    warn_lower = params.get("warn_lower", None)
    crit_lower = params.get("crit_lower", None)

    # Query all MIB entries to find the item
    res_all = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9148.3.3.1.3.1.1"], mutates=False)
    if res_all.rc != 0:
        return {"changed": False, "msg": "SNMP query failed for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse all relevant entries
    lines = res_all.stdout.splitlines()
    section = {}
    for line in lines:
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()

        base = ".1.3.6.1.4.1.9148.3.3.1.3.1.1."
        if not oid.startswith(base):
            continue
        suffix = oid[len(base):]
        if "." not in suffix:
            continue
        type_oid, idx_str = suffix.split(".", 1)
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)

        if type_oid == "3":
            if item in value:
                # Extract value and state for this index
                temp_value = 0.0
                state = "2"
                for l in lines:
                    if not l:
                        continue
                    parts2 = l.split(" = ", 1)
                    if len(parts2) != 2:
                        continue
                    oid2 = parts2[0].strip()
                    if oid2 == base + "4." + str(idx):
                        temp_value = float(parts2[1].strip())
                    elif oid2 == base + "5." + str(idx):
                        state = parts2[1].strip()

                # Map state
                ACME_ENVIRONMENT_STATES = {
                    "1": (0, "initial"),
                    "2": (0, "normal"),
                    "3": (1, "minor"),
                    "4": (2, "major"),
                    "5": (2, "critical"),
                    "6": (2, "shutdown"),
                    "7": (2, "not present"),
                    "8": (2, "not functioning"),
                    "9": (2, "unknown"),
                }
                dev_state = int(state)
                dev_state_value = 2
                dev_state_name = "unknown"
                if state in ACME_ENVIRONMENT_STATES:
                    (dev_state_value, dev_state_name) = ACME_ENVIRONMENT_STATES[state]

                # Determine state based on thresholds
                state_result = "OK"
                if crit != None and temp_value >= float(crit):
                    state_result = "CRIT"
                elif warn != None and temp_value >= float(warn):
                    state_result = "WARN"
                elif crit_lower != None and temp_value <= float(crit_lower):
                    state_result = "CRIT"
                elif warn_lower != None and temp_value <= float(warn_lower):
                    state_result = "WARN"

                # Override based on device status
                if dev_state_value == 2:
                    state_result = "CRIT"
                elif dev_state_value == 1 and state_result == "OK":
                    state_result = "WARN"

                metrics = {"acme_temp.%s" % item: temp_value}
                details = "Status: %s, Temp: %.1f" % (dev_state_name, temp_value)
                return {"changed": False,
                        "msg": "%s: %s" % (item, dev_state_name),
                        "data": {"state": state_result, "metrics": metrics, "details": details}}

    # Item not found
    return {"changed": False, "msg": "temperature sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
