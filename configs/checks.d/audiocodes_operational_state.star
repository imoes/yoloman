def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.5003.9.10.10.4.21.1"

    def snmpget(oid):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc == 0 and res.stdout.strip() != "":
            return res.stdout.strip()
        return None

    def snmpwalk(oid):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
            mutates=False,
        )
        if res.rc == 0 and res.stdout.strip() != "":
            return res.stdout.splitlines()
        return []

    def sysObjectID():
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if res.rc == 0:
            return res.stdout.strip()
        return None

    if params.get("_discover"):
        # Detect AudioCodes device via sysObjectID
        oid = sysObjectID()
        if oid == None or not oid.startswith(".1.3.6.1.4.1.5003."):
            return {"changed": False, "msg": "not an AudioCodes device", "data": {"discovery": []}}

        # Walk operational state table to get module indexes
        lines = snmpwalk(base_oid + ".8")
        if len(lines) == 0:
            return {"changed": False, "msg": "no modules found", "data": {"discovery": []}}

        discovery = []
        for line in lines:
            parts = line.split(" ", 1)
            if len(parts) < 1:
                continue
            full_oid = parts[0]
            index = full_oid[len(base_oid + ".8") + 1:]

            # Try to get a readable module name from table column 4 (acSysModulePresence)
            # and the module names section. We use the presence value as a fallback.
            # Get the module name from acSysModuleTable if available.
            # Walk the module description table at .1.3.6.1.4.1.5003.9.10.10.4.21.1.2
            # which gives acSysModuleDescr per index
            module_name_res = snmpget(base_oid + ".2." + index)
            if module_name_res != None and module_name_res != "":
                item = module_name_res
            else:
                item = "Module " + index

            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["operational_state"],
            })

        return {"changed": False, "msg": "discovered %d modules" % len(discovery), "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")

    # Verify AudioCodes device
    oid = sysObjectID()
    if oid == None or not oid.startswith(".1.3.6.1.4.1.5003."):
        return {"changed": False, "msg": "not an AudioCodes device", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Device is not an AudioCodes product (sysObjectID does not match)"}}

    # Walk the operational state column to find which index matches the item
    state_lines = snmpwalk(base_oid + ".8")
    presence_lines = snmpwalk(base_oid + ".4")
    ha_lines = snmpwalk(base_oid + ".9")
    descr_lines = snmpwalk(base_oid + ".2")

    # Build index->descr mapping
    index_to_descr = {}
    for line in descr_lines:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0]
        value = parts[1].strip().strip('"')
        index = full_oid[len(base_oid + ".2") + 1:]
        index_to_descr[index] = value

    # Build index->state mapping
    index_to_state = {}
    for line in state_lines:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0]
        value = parts[1].strip()
        index = full_oid[len(base_oid + ".8") + 1:]
        if value.isdigit():
            index_to_state[index] = int(value)

    # Build index->presence mapping
    index_to_presence = {}
    for line in presence_lines:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0]
        value = parts[1].strip()
        index = full_oid[len(base_oid + ".4") + 1:]
        if value.isdigit():
            index_to_presence[index] = int(value)

    # Build index->ha mapping
    index_to_ha = {}
    for line in ha_lines:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0]
        value = parts[1].strip()
        index = full_oid[len(base_oid + ".9") + 1:]
        if value.isdigit():
            index_to_ha[index] = int(value)

    # Find the index matching the item
    target_index = None
    if item in index_to_descr.values():
        for idx, descr in index_to_descr.items():
            if descr == item:
                target_index = idx
                break
    elif item.startswith("Module "):
        target_index = item[len("Module "):]

    if target_index == None or target_index not in index_to_state:
        return {"changed": False, "msg": "no such module: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "Module not found in operational state table"}}

    op_state = index_to_state[target_index]
    presence = index_to_presence.get(target_index, 0)
    ha = index_to_ha.get(target_index, 0)
    descr = index_to_descr.get(target_index, "Module " + target_index)

    # AudioCodes acSysModuleOperationalState values:
    # 1 = notRunning, 2 = running, 3 = fault, 4 = initializing
    state_names = {1: "notRunning", 2: "running", 3: "fault", 4: "initializing"}
    # Presence values: 1 = present, 2 = notPresent
    presence_names = {1: "present", 2: "notPresent"}
    # HA status: 1 = standalone, 2 = active, 3 = standby
    ha_names = {1: "standalone", 2: "active", 3: "standby"}

    op_name = state_names.get(op_state, "unknown(%d)" % op_state)
    pres_name = presence_names.get(presence, "unknown(%d)" % presence)
    ha_name = ha_names.get(ha, "unknown(%d)" % ha)

    if op_state == 2:
        state = "OK"
    elif op_state == 1:
        state = "WARN"
    elif op_state == 3:
        state = "CRIT"
    elif op_state == 4:
        state = "WARN"
    else:
        state = "UNKNOWN"

    details = "Module: %s\nOperational State: %s (%d)\nPresence: %s (%d)\nHA Status: %s (%d)" % (
        descr, op_name, op_state, pres_name, presence, ha_name, ha
    )

    msg = "%s: operational state %s" % (descr, op_name)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"operational_state": float(op_state)},
            "details": details,
        },
    }