IBM_STORAGE_TS_STATUS_NAME_MAP = {
    "1": "other",
    "2": "unknown",
    "3": "Ok",
    "4": "non-critical",
    "5": "critical",
    "6": "non-Recoverable",
}

IBM_STORAGE_TS_STATUS_NAGIOS_MAP = {
    "1": "WARN",
    "2": "WARN",
    "3": "OK",
    "4": "WARN",
    "5": "CRIT",
    "6": "CRIT",
}

IBM_STORAGE_TS_FAULT_NAGIOS_MAP = {
    "0": "OK",
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
    "4": "CRIT",
}

def _parse_snmp_section(stdout):
    lines = stdout.splitlines()
    if not lines:
        return None
    
    info_raw = []
    status_raw = []
    library_raw = []
    drive_raw = []
    
    current_section = None
    current_data = []
    
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        
        if stripped == "INFO":
            current_section = "info"
            info_raw = []
            current_data = info_raw
        elif stripped == "STATUS":
            current_section = "status"
            status_raw = []
            current_data = status_raw
        elif stripped == "LIBRARY":
            current_section = "library"
            library_raw = []
            current_data = library_raw
        elif stripped == "DRIVE":
            current_section = "drive"
            drive_raw = []
            current_data = drive_raw
        elif current_section != None:
            # Parse SNMP output: OID = TYPE: value
            parts = stripped.split(" = ", 1)
            if len(parts) == 2:
                oid_part = parts[0].strip()
                val_part = parts[1].strip()
                # Extract value after type (e.g., "STRING:", "INTEGER:", etc.)
                if ":" in val_part:
                    value = val_part.split(":", 1)[1].strip().strip('"')
                else:
                    value = val_part
                
                # Add to appropriate section
                if current_section == "info":
                    info_raw.append(value)
                elif current_section == "status":
                    status_raw.append(value)
                elif current_section == "library":
                    library_raw.append(value.split())
                elif current_section == "drive":
                    drive_raw.append(value.split())
    
    if not info_raw or not status_raw:
        return None
    
    info = {
        "product": info_raw[0] if len(info_raw) > 0 else "",
        "vendor": info_raw[1] if len(info_raw) > 1 else "",
        "version": info_raw[2] if len(info_raw) > 2 else "",
    }
    
    libraries = []
    for lib in library_raw:
        if len(lib) >= 7:
            libraries.append({
                "entry": lib[0],
                "status": lib[1],
                "serial": lib[2],
                "drive_count": lib[3],
                "fault": lib[4],
                "severity": lib[5],
                "descr": lib[6],
            })
    
    drives = []
    for drv in drive_raw:
        if len(drv) >= 6:
            drives.append({
                "entry": drv[0],
                "serial": drv[1],
                "write_warn": drv[2],
                "write_err": drv[3],
                "read_warn": drv[4],
                "read_err": drv[5],
            })
    
    return {
        "info": info,
        "status": status_raw[0] if len(status_raw) > 0 else "2",
        "libraries": libraries,
        "drives": drives,
    }

def _get_best_state(states):
    if "CRIT" in states:
        return "CRIT"
    elif "WARN" in states:
        return "WARN"
    elif "UNKNOWN" in states:
        return "UNKNOWN"
    else:
        return "OK"

def main(ctx, params):
    # SNMP parameters
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    if params.get("_discover"):
        # Discover mode: run snmpwalk for all sections and parse
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2.6.210"
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "SNMP query failed",
                "data": {"discovery": []}
            }
        
        section = _parse_snmp_section(res.stdout)
        
        if section == None:
            return {
                "changed": False,
                "msg": "No IBM storage TS data found",
                "data": {"discovery": []}
            }
        
        discovery_items = []
        
        # Info service
        discovery_items.append({
            "item": "",
            "params": {},
            "metrics": []
        })
        
        # Status service
        discovery_items.append({
            "item": "",
            "params": {},
            "metrics": []
        })
        
        # Library services
        for lib in section["libraries"]:
            discovery_items.append({
                "item": lib["entry"],
                "params": {},
                "metrics": []
            })
        
        # Drive services
        for drv in section["drives"]:
            discovery_items.append({
                "item": drv["entry"],
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    item = params.get("item", "")
    
    # Run SNMP query
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.2.6.210"
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    section = _parse_snmp_section(res.stdout)
    
    if section == None:
        return {
            "changed": False,
            "msg": "No IBM storage TS data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Item-specific logic
    # Info service
    if item == "" and "Info" in params.get("_service_description", ""):
        return {
            "changed": False,
            "msg": "%s %s, Version %s" % (
                section["info"]["vendor"],
                section["info"]["product"],
                section["info"]["version"]
            ),
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }
    
    # Status service
    if item == "" and "Status" in params.get("_service_description", ""):
        status = section["status"]
        nagios_state = IBM_STORAGE_TS_STATUS_NAGIOS_MAP.get(status, "UNKNOWN")
        status_name = IBM_STORAGE_TS_STATUS_NAME_MAP.get(status, "unknown")
        
        return {
            "changed": False,
            "msg": "Device Status: %s" % status_name,
            "data": {"state": nagios_state, "metrics": {}, "details": ""}
        }
    
    # Library service
    for lib in section["libraries"]:
        if item == lib["entry"]:
            state_device = IBM_STORAGE_TS_STATUS_NAGIOS_MAP.get(lib["status"], "UNKNOWN")
            fault_status = IBM_STORAGE_TS_FAULT_NAGIOS_MAP.get(lib["severity"], "UNKNOWN")
            
            # Build info text
            infotext = "Device %s, Status: %s, Drives: %s" % (
                lib["serial"],
                IBM_STORAGE_TS_STATUS_NAME_MAP.get(lib["status"], "unknown"),
                lib["drive_count"]
            )
            if lib["fault"] != "0":
                infotext += ", Fault: %s (%s)" % (lib["descr"], lib["fault"])
            
            # Determine best state
            states = [state_device, fault_status]
            final_state = _get_best_state(states)
            
            return {
                "changed": False,
                "msg": infotext,
                "data": {"state": final_state, "metrics": {}, "details": ""}
            }
    
    # Drive service
    for drv in section["drives"]:
        if item == drv["entry"]:
            states = ["OK"]
            details = "S/N: %s" % drv["serial"]
            
            # Check errors
            if drv["write_err"] != "":
                if drv["write_err"] != "0":
                    states.append("CRIT")
                    details += ", %s hard write errors" % drv["write_err"]
                elif drv["write_warn"] != "":
                    if drv["write_warn"] != "0":
                        states.append("WARN")
                        details += ", %s recovered write errors" % drv["write_warn"]
            
            if drv["read_err"] != "":
                if drv["read_err"] != "0":
                    states.append("CRIT")
                    details += ", %s hard read errors" % drv["read_err"]
                elif drv["read_warn"] != "":
                    if drv["read_warn"] != "0":
                        states.append("WARN")
                        details += ", %s recovered read errors" % drv["read_warn"]
            
            final_state = _get_best_state(states)
            
            return {
                "changed": False,
                "msg": details,
                "data": {"state": final_state, "metrics": {}, "details": ""}
            }
    
    # Item not found
    return {
        "changed": False,
        "msg": "item not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }