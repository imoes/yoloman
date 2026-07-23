def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.2.1.43.8.2.1"
        ], mutates=False)
        
        lines = res.stdout.splitlines()
        discovered_items = []
        
        for line in lines:
            if 'prtInputName' in line:
                parts = line.strip().split(" = ")
                if len(parts) != 2:
                    continue
                oid_end = parts[0].strip()
                value = parts[1].strip()
                
                if value.startswith("STRING: "):
                    name = value[8:].strip().strip('"')
                else:
                    continue
                
                # Get description
                desc_oid = oid_end.replace("prtInputName", "prtInputDescription")
                description = ""
                for l in lines:
                    if l.startswith(desc_oid + " = "):
                        v = l.split(" = ", 1)
                        if len(v) == 2:
                            val = v[1].strip()
                            if val.startswith("STRING: "):
                                description = val[8:].strip().strip('"')
                            else:
                                description = val.strip()
                        break
                
                if name == "unknown" or not name:
                    name = description if description else oid_end.rsplit(".", 1)[-1]
                
                # Get status
                status_oid = oid_end.replace("prtInputName", "prtInputStatus")
                status = ""
                for l in lines:
                    if l.startswith(status_oid + " = "):
                        v = l.split(" = ", 1)
                        if len(v) == 2:
                            val = v[1].strip()
                            if val.startswith("INTEGER: "):
                                status = val[9:].strip()
                            else:
                                status = val.strip()
                        break
                
                # Get capacity unit
                unit_oid = oid_end.replace("prtInputName", "prtInputCapacityUnit")
                unit = ""
                for l in lines:
                    if l.startswith(unit_oid + " = "):
                        v = l.split(" = ", 1)
                        if len(v) == 2:
                            val = v[1].strip()
                            if val.startswith("INTEGER: "):
                                unit = val[9:].strip()
                            else:
                                unit = val.strip()
                        break
                
                # Get max capacity
                max_oid = oid_end.replace("prtInputName", "prtInputMaxCapacity")
                max_cap = ""
                for l in lines:
                    if l.startswith(max_oid + " = "):
                        v = l.split(" = ", 1)
                        if len(v) == 2:
                            val = v[1].strip()
                            if val.startswith("INTEGER: "):
                                max_cap = val[9:].strip()
                            else:
                                max_cap = val.strip()
                        break
                
                # Get current level
                level_oid = oid_end.replace("prtInputName", "prtInputCurrentLevel")
                level = ""
                for l in lines:
                    if l.startswith(level_oid + " = "):
                        v = l.split(" = ", 1)
                        if len(v) == 2:
                            val = v[1].strip()
                            if val.startswith("INTEGER: "):
                                level = val[9:].strip()
                            else:
                                level = val.strip()
                        break
                
                # Process unit string
                unit_map = {
                    "-1": " unknown", "0": " unknown", "1": " unknown",
                    "2": " unknown", "3": " 1/10000 in", "4": " micrometers",
                    "8": " sheets", "16": " feet", "17": " meters",
                    "18": " items", "19": " percent"
                }
                if unit != "":
                    unit = " " + unit_map.get(unit, " unknown")
                
                # Parse status
                snmp_status = 0
                if status and status.isdigit():
                    snmp_status = int(status)
                
                transitioning = bool(snmp_status & 64)
                offline = bool(snmp_status & 32)
                
                # Determine alert status
                alert = "None"
                if snmp_status & 16:
                    alert = "Critical"
                elif snmp_status & 8:
                    alert = "Non-Critical"
                
                availability_code = snmp_status % 8
                availability_name = "Unknown"
                if availability_code == 0:
                    availability_name = "Available and idle"
                elif availability_code == 2:
                    availability_name = "Available and standby"
                elif availability_code == 4:
                    availability_name = "Available and active"
                elif availability_code == 6:
                    availability_name = "Available and busy"
                elif availability_code == 1:
                    availability_name = "Unavailable and on request"
                elif availability_code == 3:
                    availability_name = "Unavailable because broken"
                elif availability_code == 5:
                    availability_name = "Unknown"
                
                # Skip based on discovery rules
                if not description:
                    continue
                
                # Parse max capacity
                capacity_max = 0
                if max_cap and max_cap.isdigit():
                    capacity_max = int(max_cap)
                
                if capacity_max == 0:
                    continue
                
                # Skip broken or unknown availability
                if availability_code in [3, 5]:
                    continue
                
                discovered_items.append({
                    "item": name,
                    "params": {"capacity_levels": ("fixed", (0.0, 0.0))},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d input trays" % len(discovered_items),
            "data": {"discovery": discovered_items}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get all input data in one snmpwalk
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.2.1.43.8.2.1"
    ], mutates=False)
    
    # Find the specific tray by name
    base = ""
    lines = res.stdout.splitlines()
    
    for line in lines:
        if 'prtInputName' in line:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].strip()
            value = parts[1].strip()
            
            if value.startswith("STRING: "):
                name = value[8:].strip().strip('"')
            else:
                continue
            
            if name == item:
                base = oid_end.rsplit(".", 1)[0] + "."
                break
    
    if not base:
        return {
            "changed": False,
            "msg": "item not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Collect all data for this tray
    tray_data = {}
    for line in lines:
        if base in line:
            oid_end = line.strip().split(" = ")[0]
            value = line.strip().split(" = ", 1)[1]
            
            if value.startswith("STRING: "):
                val = value[8:].strip().strip('"')
            elif value.startswith("INTEGER: "):
                val = value[9:].strip()
            else:
                val = value.strip()
            
            if 'prtInputDescription' in oid_end:
                tray_data['description'] = val
            elif 'prtInputStatus' in oid_end:
                tray_data['status'] = val
            elif 'prtInputCapacityUnit' in oid_end:
                tray_data['capacity_unit'] = val
            elif 'prtInputMaxCapacity' in oid_end:
                tray_data['max_capacity'] = val
            elif 'prtInputCurrentLevel' in oid_end:
                tray_data['level'] = val
    
    # Verify required fields
    if not tray_data.get('description'):
        return {
            "changed": False,
            "msg": "item not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    description = tray_data.get('description', '')
    status_str = tray_data.get('status', '0')
    capacity_unit = tray_data.get('capacity_unit', '')
    max_capacity_str = tray_data.get('max_capacity', '0')
    level_str = tray_data.get('level', '-1')
    
    # Parse values
    snmp_status = 0
    if status_str and status_str.isdigit():
        snmp_status = int(status_str)
    
    capacity_max = 0
    if max_capacity_str and max_capacity_str.isdigit():
        capacity_max = int(max_capacity_str)
    
    level = -1
    if level_str and level_str.lstrip("-").isdigit():
        level = int(level_str)
    
    # Process unit string
    unit_map = {
        "-1": " unknown", "0": " unknown", "1": " unknown",
        "2": " unknown", "3": " 1/10000 in", "4": " micrometers",
        "8": " sheets", "16": " feet", "17": " meters",
        "18": " items", "19": " percent"
    }
    if capacity_unit != "":
        capacity_unit = " " + unit_map.get(capacity_unit, " unknown")
    
    # Parse availability
    availability_code = snmp_status % 8
    availability_name = "Unknown"
    if availability_code == 0:
        availability_name = "Available and idle"
    elif availability_code == 2:
        availability_name = "Available and standby"
    elif availability_code == 4:
        availability_name = "Available and active"
    elif availability_code == 6:
        availability_name = "Available and busy"
    elif availability_code == 1:
        availability_name = "Unavailable and on request"
    elif availability_code == 3:
        availability_name = "Unavailable because broken"
    elif availability_code == 5:
        availability_name = "Unknown"
    
    # Check states
    offline = bool(snmp_status & 32)
    transitioning = bool(snmp_status & 64)
    
    # Determine alert status
    alert = "None"
    if snmp_status & 16:
        alert = "Critical"
    elif snmp_status & 8:
        alert = "Non-Critical"
    
    # Build state and summary
    state = "OK"
    summary_parts = []
    
    if description:
        summary_parts.append(description)
    
    if offline:
        state = "CRIT"
        summary_parts.append("Offline")
    else:
        # Get state from availability code
        if availability_code in [0, 2, 4, 6]:  # Available states
            state = "OK"
        elif availability_code == 1:  # On request
            state = "WARN"
        elif availability_code == 3:  # Broken
            state = "CRIT"
        elif availability_code == 5:  # Unknown
            state = "UNKNOWN"
        
        summary_parts.append("Status: %s" % availability_name)
    
    summary_parts.append("Alerts: %s" % alert)
    
    if transitioning:
        summary_parts.append("Transitioning")
    
    # Check capacity levels if valid
    capacity_percent = None
    if level != -1 and level != -2 and level > -3:
        if capacity_max != -2 and capacity_max != -1 and capacity_max != 0:
            # Calculate percentage
            capacity_percent = 100.0 * level / capacity_max
            
            summary_parts.append("Remaining: %d%%" % int(capacity_percent))
            
            # Determine levels
            levels = params.get("capacity_levels", ("fixed", (0.0, 0.0)))
            if levels[0] == "fixed":
                warn, crit = levels[1]
                if capacity_percent <= crit:
                    state = "CRIT"
                elif capacity_percent <= warn:
                    if state not in ["CRIT"]:
                        state = "WARN"
    
    summary = ", ".join(summary_parts)
    
    # Prepare metrics
    metrics = {}
    if capacity_percent != None:
        metrics["remaining_percent"] = capacity_percent
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }