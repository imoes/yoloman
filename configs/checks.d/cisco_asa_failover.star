def main(ctx, params):
    # Constants for state mapping (1: other, 2: up, 3: down, 4: error, etc.)
    STATE_NAMES = {
        "1": "other", "2": "up", "3": "down", "4": "error", "5": "overTemp",
        "6": "busy", "7": "noMedia", "8": "backup", "9": "active", "10": "standby"
    }
    
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {
                        "primary": "active",
                        "secondary": "standby",
                        "failover_state": 1,
                        "failover_link_state": 2,
                        "not_active_standby_state": 1
                    }, "metrics": []}
                ]
            }
        }
    
    # Check mode for single service (item is always "" as discovered above)
    # Fetch SNMP data from cisco_asa_failover section
    base_oid = ".1.3.6.1.4.1.9.9.147.1.2.1.1.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), base_oid
    ], mutates=False)
    
    # Parse SNMP output: lines look like "OID = TYPE: value"
    # We need to extract rows where the OID ends with .2, .3, or .4
    # Group by last numeric part (4, 6, 7) which corresponds to instance index
    # .2 = cfwHardwareInformation (role), .3 = cfwHardwareStatusValue, .4 = cfwHardwareStatusDetail
    
    data = {}
    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract last component of OID
        last_oid = oid_part.rsplit(".", 1)[-1]
        
        # Map OID index to section component: 2, 3, or 4
        if last_oid not in ["2", "3", "4"]:
            continue
        
        # Extract instance index (e.g., 4, 6, 7 from ...1.1.2.4)
        # Find position of base OID and then extract next number
        if not oid_part.startswith(base_oid + "."):
            continue
        remainder = oid_part[len(base_oid) + 1:]
        parts_oid = remainder.split(".")
        if len(parts_oid) < 2:
            continue
        instance = parts_oid[-1]
        
        # Organize data by instance
        if instance not in data:
            data[instance] = {}
        
        if last_oid == "2":
            data[instance]["role"] = value_part
        elif last_oid == "3":
            data[instance]["status"] = value_part
        elif last_oid == "4":
            data[instance]["detail"] = value_part
    
    # Build section from instances with "this device", "secondary unit", etc.
    section = {
        "local_role": "",
        "local_status": "",
        "local_status_detail": "",
        "failover_link_status": "",
        "failover_link_name": "",
        "remote_status": ""
    }
    
    for inst, vals in data.items():
        role = vals.get("role", "").lower()
        if "this device" in role or "primary" in role:
            section["local_status"] = vals.get("status", "")
            section["local_status_detail"] = vals.get("detail", "")
            section["local_role"] = "primary" if "primary" in role or "this device" in role else "secondary"
        elif "failover" in role:
            section["failover_link_status"] = vals.get("status", "")
            section["failover_link_name"] = vals.get("detail", "")
        else:
            # Secondary unit or remote device
            if vals.get("detail", "").lower() != "failover off":
                section["remote_status"] = vals.get("status", "")
    
    # Ensure required fields are present
    if not section["local_status"]:
        return {
            "changed": False,
            "msg": "No failover data found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "No failover data found"
            }
        }
    
    # Default params from Checkmk plugin
    primary = params.get("primary", "active")
    secondary = params.get("secondary", "standby")
    failover_state = params.get("failover_state", 1)
    failover_link_state = params.get("failover_link_state", 2)
    not_active_standby_state = params.get("not_active_standby_state", 1)
    
    # Helper: map numeric status to name
    def get_status_name(st):
        return STATE_NAMES.get(st, "unknown %s" % st)
    
    # Build summary
    state = "OK"
    details_list = []
    
    # First result: device role and detail
    details_list.append("Device (%s) is the %s" % (section["local_role"], section["local_status_detail"]))
    
    # Second result: check local status matches expected
    expected_local = primary if section["local_role"] == "primary" else secondary
    actual_status_name = get_status_name(section["local_status"])
    if expected_local != actual_status_name:
        state = "WARN" if state == "OK" else state
        details_list.append("(The %s device should be %s)" % (section["local_role"], expected_local))
    
    # Third/fourth results: local and remote must be active/standby
    if section["local_status"] not in ["9", "10"]:  # not active/standby
        state = "WARN" if state == "OK" else state
        details_list.append("Unhandled state %s reported" % actual_status_name)
    
    if section["remote_status"] not in ["9", "10"]:  # not active/standby
        state = "WARN" if state == "OK" else state
        details_list.append("Unhandled state %s for remote device reported" % get_status_name(section["remote_status"]))
    
    # Fifth result: failover link must be up
    if section["failover_link_status"] != "2":
        state = "CRIT" if state == "OK" else state
        details_list.append("Failover link %s state is %s" % (
            section["failover_link_name"],
            get_status_name(section["failover_link_status"])
        ))
    
    # Final state mapping: CRIT=2, WARN=1, OK=0
    if state == "CRIT":
        final_state = "CRIT"
    elif state == "WARN":
        final_state = "WARN"
    else:
        final_state = "OK"
    
    return {
        "changed": False,
        "msg": "; ".join(details_list),
        "data": {
            "state": final_state,
            "metrics": {},
            "details": ""
        }
    }
