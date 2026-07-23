def main(ctx, params):
    # === Constants ===
    SNMP_COMMUNITY = params.get("community", "public")
    SNMP_HOST = params.get("host", "localhost")
    OID_BASE_ENT_PHYS_NAME = ".1.3.6.1.2.1.47.1.1.1.1.7"
    OID_BASE_ENT_PHY_SENSOR_TYPE = ".1.3.6.1.2.1.99.1.1.1.1.2"
    OID_BASE_ENT_PHY_SENSOR_VALUE = ".1.3.6.1.2.1.99.1.1.1.1.4"
    OID_BASE_ENT_PHY_SENSOR_OPER_STATUS = ".1.3.6.1.2.1.99.1.1.1.1.5"
    OID_BASE_ENT_PHY_SENSOR_UNITS = ".1.3.6.1.2.1.99.1.1.1.1.6"
    OID_SYSDESCR = ".1.3.6.1.2.1.1.1.0"

    # Power presence sensor type value per SNMP Vendors MIBs (typically 6 = powerSupply)
    POWER_PRESENCE_TYPE = 6

    # === Discovery mode ===
    if params.get("_discover"):
        # Detect target device by sysDescr
        res_sysdesc = ctx.run(["snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, OID_SYSDESCR], mutates=False)
        sysdesc = ""
        for line in res_sysdesc.stdout.splitlines():
            if line.startswith(OID_SYSDESCR):
                sysdesc = line.split(" = STRING: ", 1)[-1].strip('"')
                break
        detected = sysdesc.lower().startswith("palo alto networks") or \
                   sysdesc.lower().startswith("cisco adaptive security appliance") or \
                   sysdesc.lower().startswith("arista networks")

        if not detected:
            return {"changed": False, "msg": "discovered 0 items (device not matched)",
                    "data": {"discovery": []}}

        # Fetch all power presence sensors: type=6 and value in {0,1}
        res_type = ctx.run(["snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, OID_BASE_ENT_PHY_SENSOR_TYPE], mutates=False)
        res_value = ctx.run(["snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, OID_BASE_ENT_PHY_SENSOR_VALUE], mutates=False)
        res_status = ctx.run(["snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, OID_BASE_ENT_PHY_SENSOR_OPER_STATUS], mutates=False)

        # Map OID end to value for each OID set
        def parse_snmp_walk(output):
            mapping = {}
            for line in output.splitlines():
                parts = line.strip().split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_full, value_raw = parts
                oid_end = oid_full.rsplit(".", 1)[-1]
                value = value_raw.split(": ", 1)[-1].strip()
                # Extract numeric value for integers
                if value.isdigit():
                    mapping[oid_end] = int(value)
                elif value == "integer: " + str(value):
                    mapping[oid_end] = int(value.split(" ")[-1])
                else:
                    mapping[oid_end] = value
            return mapping

        type_map = parse_snmp_walk(res_type.stdout)
        value_map = parse_snmp_walk(res_value.stdout)
        status_map = parse_snmp_walk(res_status.stdout)

        # Collect power presence items (type == 6 and value in [0,1])
        items = []
        for oid_end in type_map:
            if type_map.get(oid_end) == POWER_PRESENCE_TYPE and value_map.get(oid_end) in (0, 1):
                # Get item name from ENTITY-MIB entPhysicalName
                name_oid = OID_BASE_ENT_PHYS_NAME + "." + oid_end
                res_name = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, name_oid], mutates=False)
                name = ""
                for ln in res_name.stdout.splitlines():
                    if ln.startswith(name_oid):
                        name = ln.split(" = STRING: ", 1)[-1].strip('"')
                        break
                if not name:
                    name = "Power " + oid_end
                items.append({
                    "item": name,
                    "params": {"power_off_criticality": 1},
                    "metrics": []
                })

        return {"changed": False, "msg": "discovered %d power presence sensors" % len(items),
                "data": {"discovery": items}}

    # === Check mode ===
    item = params.get("item", "")
    power_off_criticality = params.get("power_off_criticality", 1)

    # Fetch all power presence sensors to find the requested item
    res_type = ctx.run(["snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, OID_BASE_ENT_PHY_SENSOR_TYPE], mutates=False)
    res_value = ctx.run(["snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, OID_BASE_ENT_PHY_SENSOR_VALUE], mutates=False)

    type_map = {}
    value_map = {}
    for line in res_type.stdout.splitlines():
        parts = line.strip().split(" = ", 1)
        if len(parts) == 2:
            oid_full, value_raw = parts
            oid_end = oid_full.rsplit(".", 1)[-1]
            if value_raw.endswith("integer: "):
                type_map[oid_end] = int(value_raw.split("integer: ")[-1])
            elif value_raw.split(": ")[-1].strip().isdigit():
                type_map[oid_end] = int(value_raw.split(": ")[-1].strip())
    for line in res_value.stdout.splitlines():
        parts = line.strip().split(" = ", 1)
        if len(parts) == 2:
            oid_full, value_raw = parts
            oid_end = oid_full.rsplit(".", 1)[-1]
            if value_raw.endswith("integer: "):
                value_map[oid_end] = int(value_raw.split("integer: ")[-1])
            elif value_raw.split(": ")[-1].strip().isdigit():
                value_map[oid_end] = int(value_raw.split(": ")[-1].strip())

    # Find matching OID by item name via entPhysicalName
    found = False
    for oid_end in type_map:
        if type_map.get(oid_end) != POWER_PRESENCE_TYPE or value_map.get(oid_end) not in (0, 1):
            continue
        name_oid = OID_BASE_ENT_PHYS_NAME + "." + oid_end
        res_name = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, name_oid], mutates=False)
        for ln in res_name.stdout.splitlines():
            if ln.startswith(name_oid):
                name = ln.split(" = STRING: ", 1)[-1].strip('"')
                if name == item:
                    found = True
                    value = value_map.get(oid_end)
                    # Map reading: 1 = powered on (OK), 0 = powered off
                    if value == 1:
                        return {
                            "changed": False,
                            "msg": "Powered on",
                            "data": {
                                "state": "OK",
                                "metrics": {},
                                "details": ""
                            }
                        }
                    # powered off
                    state_str = "CRIT" if power_off_criticality == 2 else "WARN"
                    return {
                        "changed": False,
                        "msg": "Powered off",
                        "data": {
                            "state": state_str,
                            "metrics": {},
                            "details": ""
                        }
                    }

    # Not found
    return {
        "changed": False,
        "msg": "Power presence sensor not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
