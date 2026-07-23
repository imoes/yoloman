def main(ctx, params):
    # Constants for SNMP OIDs and state mappings (defined at module level)
    OID_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.27.21.1"
    OID_END = ".1.3.6.1.4.1.5003.9.10.10.4.27.21.1.{}.8"
    OID_PRESENT = ".1.3.6.1.4.1.5003.9.10.10.4.27.21.1.{}.4"
    OID_HA_STATUS = ".1.3.6.1.4.1.5003.9.10.10.4.27.21.1.{}.9"

    # State mappings (from Checkmk source)
    PRESENCE_MAP = {"1": "absent", "2": "present"}
    HA_STATUS_MAP = {
        "1": "standalone",
        "2": "master",
        "3": "slave",
        "4": "unknown",
        "5": "disabled",
        "6": "notInstalled",
        "7": "notCompatible",
        "8": "error",
    }
    OPERATIONAL_STATE_MAP = {
        "1": "enabled",
        "2": "disabled",
        "3": "failed",
        "4": "maintenance",
        "5": "booting",
        "6": "ready",
        "7": "unknown",
        "8": "notInstalled",
        "9": "notCompatible",
        "10": "error",
    }

    # Discovery mode
    if params.get("_discover"):
        # Walk the SNMP tree to discover all modules
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            OID_BASE,
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}

        # Parse the output to extract module IDs and their operational states
        discovered = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value_raw = parts[1].strip()
            
            # Extract module ID from the OID (last part after the base)
            # Format: OID_BASE.module_id.oid_type = value
            base_parts = OID_BASE.split(".")
            oid_parts = oid_full.split(".")
            if len(oid_parts) != len(base_parts) + 2:
                continue  # Skip non-matching lines
            module_id = oid_parts[-2]  # The module ID
            value = value_raw
            if ": " in value_raw:
                value = value_raw.split(": ", 1)[1].strip()

            # Collect values per module_id
            if module_id not in [d.get("item", "") for d in discovered]:
                discovered.append({"item": module_id, "params": {}, "metrics": []})

        # Return discovery result
        return {"changed": False, "msg": "discovered %d modules" % len(discovered),
                "data": {"discovery": discovered}}

    # Check mode (for a specific item)
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch individual OIDs for the item (module)
    res_op = ctx.run([
        "snmpget",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        OID_END.format(item),
    ], mutates=False)
    res_pres = ctx.run([
        "snmpget",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        OID_PRESENT.format(item),
    ], mutates=False)
    res_ha = ctx.run([
        "snmpget",
        "-v2c",
        "-c",
        params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        OID_HA_STATUS.format(item),
    ], mutates=False)

    # Helper to extract value from snmpget output
    def get_value(res):
        if res.rc != 0 or not res.stdout.strip():
            return None
        parts = res.stdout.strip().split(" = ")
        if len(parts) != 2:
            return None
        value_raw = parts[1].strip()
        if ": " in value_raw:
            return value_raw.split(": ", 1)[1].strip()
        return value_raw

    op_state = get_value(res_op)
    presence = get_value(res_pres)
    ha_status = get_value(res_ha)

    # Map operational state to Checkmk status
    state = "UNKNOWN"
    msg = "module %s: operational state unknown" % item

    if presence != None and PRESENCE_MAP.get(presence) == "absent":
        state = "CRIT"
        msg = "module %s: absent" % item
    elif op_state != None and OPERATIONAL_STATE_MAP.get(op_state) == "failed":
        state = "CRIT"
        msg = "module %s: %s" % (item, OPERATIONAL_STATE_MAP[op_state])
    elif op_state != None and OPERATIONAL_STATE_MAP.get(op_state) == "maintenance":
        state = "WARN"
        msg = "module %s: %s" % (item, OPERATIONAL_STATE_MAP[op_state])
    elif op_state != None and OPERATIONAL_STATE_MAP.get(op_state) == "enabled":
        state = "OK"
        msg = "module %s: operational" % item
    elif op_state != None and OPERATIONAL_STATE_MAP.get(op_state) == "ready":
        state = "OK"
        msg = "module %s: %s" % (item, OPERATIONAL_STATE_MAP[op_state])
    else:
        state = "UNKNOWN"
        msg = "module %s: no data" % item

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}
