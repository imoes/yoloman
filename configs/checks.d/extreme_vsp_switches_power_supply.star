def main(ctx, params):
    # Constants for SNMP OIDs and mappings
    OID_BASE_POWER_SUPPLY = ".1.3.6.1.4.1.2272.1.4.8.1.1"
    OID_POWER_SUPPLY_ID = "1"
    OID_POWER_SUPPLY_OPER_STATUS = "2"
    OID_BASE_POWER_DETAIL = ".1.3.6.1.4.1.2272.1.4.8.2.1"
    OID_POWER_DETAIL_ID = "1"
    OID_POWER_DETAIL_PSE_POWER = "7"
    OID_POWER_DETAIL_INPUT_LINE_VOLTAGE = "8"
    OID_POWER_DETAIL_OUTPUT_WATTS = "10"

    # Detect NetExtreme device via SNMP sysObjectID
    res_detect = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"
    ], mutates=False)
    if res_detect.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    sys_objectid = res_detect.stdout.strip().split()[-1] if res_detect.stdout.strip().split() else ""
    is_netextreme = (sys_objectid.startswith(".1.3.6.1.4.1.1916.2") or
                     sys_objectid.startswith(".1.3.6.1.4.1.2272.2") or
                     sys_objectid.startswith(".1.3.6.1.4.1.2272.202") or
                     sys_objectid.startswith(".1.3.6.1.4.1.2272.209") or
                     sys_objectid.startswith(".1.3.6.1.4.1.2272.220") or
                     sys_objectid.startswith(".1.3.6.1.4.1.2272.212"))

    if not is_netextreme:
        return {
            "changed": False,
            "msg": "device is not a NetExtreme device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Discovery mode
    if params.get("_discover"):
        res_power = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            OID_BASE_POWER_SUPPLY + "." + OID_POWER_SUPPLY_ID,
            OID_BASE_POWER_SUPPLY + "." + OID_POWER_SUPPLY_OPER_STATUS
        ], mutates=False)
        if res_power.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP query failed for power supplies",
                "data": {"discovery": []}
            }

        # Parse discovered power supplies
        power_ids = []
        for line in res_power.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid_tail = parts[0].rsplit(".", 1)[-1]
            if oid_tail == OID_POWER_SUPPLY_ID:
                power_ids.append(parts[1])

        items = list(set(power_ids))  # unique IDs

        discovery_list = []
        for item in items:
            discovery_list.append({
                "item": item,
                "params": {},
                "metrics": []
            })

        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch both SNMP tables
    res_power = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        OID_BASE_POWER_SUPPLY + "." + OID_POWER_SUPPLY_ID,
        OID_BASE_POWER_SUPPLY + "." + OID_POWER_SUPPLY_OPER_STATUS
    ], mutates=False)

    res_detail = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        OID_BASE_POWER_DETAIL + "." + OID_POWER_DETAIL_ID,
        OID_BASE_POWER_DETAIL + "." + OID_POWER_DETAIL_PSE_POWER,
        OID_BASE_POWER_DETAIL + "." + OID_POWER_DETAIL_INPUT_LINE_VOLTAGE,
        OID_BASE_POWER_DETAIL + "." + OID_POWER_DETAIL_OUTPUT_WATTS
    ], mutates=False)

    if res_power.rc != 0 or res_detail.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse power supplies
    power_supplies = {}
    for line in res_power.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid_path = parts[0]
        value = parts[1]
        if oid_path.endswith("." + OID_POWER_SUPPLY_ID):
            ps_id = value
            if ps_id not in power_supplies:
                power_supplies[ps_id] = {"id": ps_id, "operational_status": None}
        elif oid_path.endswith("." + OID_POWER_SUPPLY_OPER_STATUS):
            # Extract ID from OID tail
            tail = oid_path.rsplit(".", 1)[-1]
            if tail.isdigit() and tail in power_supplies:
                power_supplies[tail]["operational_status"] = value

    # Parse power details
    for line in res_detail.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid_path = parts[0]
        value = parts[1]
        if oid_path.endswith("." + OID_POWER_DETAIL_ID):
            ps_id = value
            if ps_id not in power_supplies:
                power_supplies[ps_id] = {"id": ps_id, "operational_status": None, "power_info": {}}
            else:
                power_supplies[ps_id]["power_info"] = {}
        elif oid_path.endswith("." + OID_POWER_DETAIL_PSE_POWER):
            tail = oid_path.rsplit(".", 1)[-1]
            if tail in power_supplies:
                power_supplies[tail]["power_info"]["pse_power"] = value
        elif oid_path.endswith("." + OID_POWER_DETAIL_INPUT_LINE_VOLTAGE):
            tail = oid_path.rsplit(".", 1)[-1]
            if tail in power_supplies:
                power_supplies[tail]["power_info"]["input_line_voltage"] = value
        elif oid_path.endswith("." + OID_POWER_DETAIL_OUTPUT_WATTS):
            tail = oid_path.rsplit(".", 1)[-1]
            if tail in power_supplies:
                power_supplies[tail]["power_info"]["output_watts"] = value

    # Map input voltage values
    map_input_voltage = {
        "0": "unknown",
        "1": "low110v",
        "2": "high220v",
        "3": "minus48v",
        "4": "ac110vOr220v",
        "5": "dc",
    }

    # Map power supply status
    map_power_status = {
        "1": ("UNKNOWN", "unknown - status can not be determined"),
        "2": ("WARN", "empty - power supply not installed"),
        "3": ("OK", "up - present and supplying power"),
        "4": ("CRIT", "down - present, but failure indicated"),
    }

    # Look up item
    if item not in power_supplies:
        return {
            "changed": False,
            "msg": "power supply not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    ps = power_supplies[item]
    status = ps.get("operational_status", "")
    state_name, state_readable = map_power_status.get(status, ("UNKNOWN", "Unknown power supply status: " + str(status)))

    # Build summary message and metrics
    summaries = ["Operational status: " + state_readable]

    # Input voltage
    if ps.get("power_info", {}).get("input_line_voltage"):
        voltage_val = ps["power_info"]["input_line_voltage"]
        if voltage_val in map_input_voltage:
            voltage_name = map_input_voltage[voltage_val]
        else:
            voltage_name = "unknown"
        summaries.append("Input Line Voltage " + voltage_name)

    # Output watts
    if ps.get("power_info", {}).get("output_watts"):
        summaries.append("Output Watts: " + str(ps["power_info"]["output_watts"]))

    # PSE power
    if ps.get("power_info", {}).get("pse_power"):
        summaries.append("PSE Power: " + str(ps["power_info"]["pse_power"]))

    # No power information available
    if not ps.get("power_info"):
        summaries.append("No power information available for this power supply.")

    summary_msg = ", ".join(summaries)

    return {
        "changed": False,
        "msg": summary_msg,
        "data": {
            "state": state_name,
            "metrics": {},
            "details": ""
        }
    }
