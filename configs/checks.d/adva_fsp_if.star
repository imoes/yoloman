def main(ctx, params):
    # Constants for monitored types and admin states
    _MONITORED_TYPES = ["1", "6", "56"]
    _MONITORED_ADMIN_STATES = ["1"]
    _MAP_OPER_STATUS = {
        "1": ("up", "OK"),
        "2": ("down", "CRIT"),
        "3": ("testing", "WARN"),
        "4": ("unknown", "UNKNOWN"),
        "5": ("dormant", "WARN"),
        "6": ("notPresent", "CRIT"),
        "7": ("lowerLayerDown", "CRIT"),
    }
    
    # Discovery mode
    if params.get("_discover"):
        # Gather SNMP data
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.2.1.2.2.1.1",  # ifIndex
            ".1.3.6.1.2.1.2.2.1.2",  # ifDescr
            ".1.3.6.1.2.1.2.2.1.3",  # ifType
            ".1.3.6.1.2.1.2.2.1.7",  # ifAdminStatus
            ".1.3.6.1.2.1.2.2.1.8",  # ifOperStatus
            ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1.4",  # opticalIfDiagOutputPower
            ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1.3",  # opticalIfDiagInputPower
        ], mutates=False)
        
        # Parse SNMP walk output
        lines = res.stdout.splitlines() if res.stdout else []
        section = {}
        
        for line in lines:
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split("=", 1)
            oid = parts[0].strip()
            value = parts[1].strip() if len(parts) > 1 else ""
            
            # Extract index from OID (last component after the last dot)
            idx = ""
            if ".1.3.6.1.2.1.2.2.1." in oid or ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1." in oid:
                last_dot_pos = oid.rfind(".")
                if last_dot_pos > 0:
                    idx = oid[last_dot_pos + 1:]
            
            if not idx:
                continue
            
            # Get OID number (second to last component)
            oid_num = ""
            last_dot_pos = oid.rfind(".")
            if last_dot_pos > 0:
                second_last_dot_pos = oid.rfind(".", 0, last_dot_pos)
                if second_last_dot_pos >= 0:
                    oid_num = oid[second_last_dot_pos + 1:last_dot_pos]
            
            if idx not in section:
                section[idx] = {}
            
            # Map OID number to field name
            if oid_num == "1":
                section[idx]["ifIndex"] = value
            elif oid_num == "2":
                section[idx]["name"] = value
            elif oid_num == "3":
                # Could be ifType or input power - check base OID
                if oid.startswith(".1.3.6.1.2.1.2.2.1."):
                    section[idx]["ifType"] = value
                elif oid.startswith(".1.3.6.1.4.1.2544.1.11.2.4.3.5.1."):
                    section[idx]["input"] = value
            elif oid_num == "7":
                section[idx]["admin_status"] = value
            elif oid_num == "8":
                section[idx]["oper_status"] = value
            elif oid_num == "4":
                if oid.startswith(".1.3.6.1.4.1.2544.1.11.2.4.3.5.1."):
                    section[idx]["output"] = value
        
        # Build discovery items
        out = []
        for idx, interface in section.items():
            # Get the interface name (prefer ifDescr over ifIndex)
            name = interface.get("name", "")
            if not name:
                name = interface.get("ifIndex", idx)
            
            # Check monitored criteria
            if_type = interface.get("ifType", "")
            admin_status = interface.get("admin_status", "")
            
            # We need type to be monitored and admin status up
            if if_type in _MONITORED_TYPES and admin_status in _MONITORED_ADMIN_STATES:
                out.append({
                    "item": name,
                    "params": {"limits_input_power": [None, None], "limits_output_power": [None, None]},
                    "metrics": ["input_power", "output_power"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Gather SNMP data
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.2.1.2.2.1.1",  # ifIndex
        ".1.3.6.1.2.1.2.2.1.2",  # ifDescr
        ".1.3.6.1.2.1.2.2.1.3",  # ifType
        ".1.3.6.1.2.1.2.2.1.7",  # ifAdminStatus
        ".1.3.6.1.2.1.2.2.1.8",  # ifOperStatus
        ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1.4",  # opticalIfDiagOutputPower
        ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1.3",  # opticalIfDiagInputPower
    ], mutates=False)
    
    # Parse output to build section
    section = {}
    lines = res.stdout.splitlines() if res.stdout else []
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        oid = parts[0].strip()
        value = parts[1].strip() if len(parts) > 1 else ""
        
        # Extract index
        idx = ""
        if ".1.3.6.1.2.1.2.2.1." in oid or ".1.3.6.1.4.1.2544.1.11.2.4.3.5.1." in oid:
            last_dot_pos = oid.rfind(".")
            if last_dot_pos > 0:
                idx = oid[last_dot_pos + 1:]
        
        if not idx:
            continue
        
        # Get OID number
        oid_num = ""
        last_dot_pos = oid.rfind(".")
        if last_dot_pos > 0:
            second_last_dot_pos = oid.rfind(".", 0, last_dot_pos)
            if second_last_dot_pos >= 0:
                oid_num = oid[second_last_dot_pos + 1:last_dot_pos]
        
        if idx not in section:
            section[idx] = {}
        
        # Map OID number to field name
        if oid_num == "1":
            section[idx]["ifIndex"] = value
        elif oid_num == "2":
            section[idx]["name"] = value
        elif oid_num == "3":
            if oid.startswith(".1.3.6.1.2.1.2.2.1."):
                section[idx]["ifType"] = value
            elif oid.startswith(".1.3.6.1.4.1.2544.1.11.2.4.3.5.1."):
                section[idx]["input"] = value
        elif oid_num == "7":
            section[idx]["admin_status"] = value
        elif oid_num == "8":
            section[idx]["oper_status"] = value
        elif oid_num == "4":
            if oid.startswith(".1.3.6.1.4.1.2544.1.11.2.4.3.5.1."):
                section[idx]["output"] = value
    
    # Find the interface by item name
    interface = None
    for idx, int_data in section.items():
        name = int_data.get("name", "")
        if not name:
            name = int_data.get("ifIndex", idx)
        if name == item:
            interface = int_data
            break
    
    if not interface:
        return {
            "changed": False,
            "msg": "interface '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get status values
    admin_status = interface.get("admin_status", "")
    oper_status = interface.get("oper_status", "")
    output_power = interface.get("output", "-65535")
    input_power = interface.get("input", "-65535")
    
    # Map statuses to states
    admintxt, adminstate = _MAP_OPER_STATUS.get(admin_status, ("unknown", "UNKNOWN"))
    opertxt, operstate = _MAP_OPER_STATUS.get(oper_status, ("unknown", "UNKNOWN"))
    
    # Determine worst state
    state_map = {"OK": 0, "UNKNOWN": 1, "WARN": 2, "CRIT": 3}
    state_int = max(state_map.get(adminstate, 1), state_map.get(operstate, 1))
    state = {0: "OK", 1: "UNKNOWN", 2: "WARN", 3: "CRIT"}.get(state_int, "UNKNOWN")
    
    # Check power levels
    metrics = {}
    summary_parts = []
    summary_parts.append("Admin/Operational State: %s/%s" % (admintxt, opertxt))
    
    # Output power
    output_power_val = None
    if output_power:
        output_power_val = float(output_power) / 10.0 if output_power.lstrip("-").isdigit() or (output_power.count(".") == 1 and output_power.replace(".", "").lstrip("-").isdigit()) else None
    
    if output_power_val != None:
        summary_parts.append("Output power: %f dBm" % output_power_val)
        metrics["output_power"] = output_power_val
    
    # Input power
    input_power_val = None
    if input_power:
        input_power_val = float(input_power) / 10.0 if input_power.lstrip("-").isdigit() or (input_power.count(".") == 1 and input_power.replace(".", "").lstrip("-").isdigit()) else None
    
    if input_power_val != None:
        summary_parts.append("Input power: %f dBm" % input_power_val)
        metrics["input_power"] = input_power_val
    
    # Check against thresholds if provided
    output_mon_state = "OK"
    input_mon_state = "OK"
    
    if output_power_val != None and "limits_output_power" in params:
        limits = params["limits_output_power"]
        if len(limits) >= 2 and limits[0] != None and limits[1] != None:
            if output_power_val < float(limits[0]) or output_power_val > float(limits[1]):
                output_mon_state = "CRIT"
    
    if input_power_val != None and "limits_input_power" in params:
        limits = params["limits_input_power"]
        if len(limits) >= 2 and limits[0] != None and limits[1] != None:
            if input_power_val < float(limits[0]) or input_power_val > float(limits[1]):
                input_mon_state = "CRIT"
    
    # Update state if power checks are worse
    if state_map.get(output_mon_state, 1) > state_map.get(state, 1):
        state = output_mon_state
    if state_map.get(input_mon_state, 1) > state_map.get(state, 1):
        state = input_mon_state
    
    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }