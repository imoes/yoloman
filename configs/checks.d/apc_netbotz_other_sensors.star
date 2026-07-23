def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # SNMP OIDs for other numeric sensors (both v2 and v50 devices)
        # For v2: base .1.3.6.1.4.1.5528.100.4.2.10.1
        # For v50: base .1.3.6.1.4.1.52674.500.4.2.10.1
        # We'll try both and use whichever returns data
        
        # Try v2 first
        v2_oids = ["1.3.6.1.4.1.5528.100.4.2.10.1.4", "1.3.6.1.4.1.5528.100.4.2.10.1.3", "1.3.6.1.4.1.5528.100.4.2.10.1.7"]
        v2_res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost"] + v2_oids, mutates=False)
        
        # Try v50 as fallback
        v50_oids = ["1.3.6.1.4.1.52674.500.4.2.10.1.4", "1.3.6.1.4.1.52674.500.4.2.10.1.3", "1.3.6.1.4.1.52674.500.4.2.10.1.7"]
        v50_res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost"] + v50_oids, mutates=False)
        
        # Parse results - look for non-empty state_readable values
        # We expect lines like:
        # OID.399845582 = Wasserstand_FG1
        # OID.399845582 = 0
        # OID.399845582 = No Leak
        
        sensors = []
        
        # Simple parser: extract sensor data from snmpwalk output
        def parse_snmp_output(res, base_oid):
            if res.rc != 0:
                return []
            
            lines = res.stdout.splitlines()
            sensors_dict = {}
            
            for line in lines:
                # Format: OID.value = string or number
                if " = " not in line:
                    continue
                    
                parts = line.split(" = ")
                if len(parts) != 2:
                    continue
                    
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                
                # Extract the sensor ID (last part after last dot)
                sensor_id = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
                
                if sensor_id not in sensors_dict:
                    sensors_dict[sensor_id] = {"label": "", "error_state": "", "state_readable": ""}
                
                # Determine field type by base OID
                if base_oid == "1.3.6.1.4.1.5528.100.4.2.10.1" or base_oid == "1.3.6.1.4.1.52674.500.4.2.10.1":
                    if oid_part.startswith("1.3.6.1.4.1.5528.100.4.2.10.1.4") or oid_part.startswith("1.3.6.1.4.1.52674.500.4.2.10.1.4"):
                        sensors_dict[sensor_id]["label"] = value_part.strip('"')
                    elif oid_part.startswith("1.3.6.1.4.1.5528.100.4.2.10.1.3") or oid_part.startswith("1.3.6.1.4.1.52674.500.4.2.10.1.3"):
                        sensors_dict[sensor_id]["error_state"] = value_part
                    elif oid_part.startswith("1.3.6.1.4.1.5528.100.4.2.10.1.7") or oid_part.startswith("1.3.6.1.4.1.52674.500.4.2.10.1.7"):
                        sensors_dict[sensor_id]["state_readable"] = value_part.strip('"')
            
            return sensors_dict.values()
        
        # Try v2 sensors
        v2_sensors = parse_snmp_output(v2_res, "1.3.6.1.4.1.5528.100.4.2.10.1")
        
        # Try v50 sensors if v2 didn't yield results
        if len(v2_sensors) == 0:
            v50_sensors = parse_snmp_output(v50_res, "1.3.6.1.4.1.52674.500.4.2.10.1")
            sensors = v50_sensors
        else:
            sensors = v2_sensors
        
        # Discovery: yield one service if any sensor has non-empty state_readable
        for sensor in sensors:
            if sensor.get("state_readable", "") != "":
                return {
                    "changed": False,
                    "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
                }
        
        # No sensors found
        return {"changed": False, "msg": "no numeric sensors found", "data": {"discovery": []}}
    
    # Check mode - single service check
    # We need to re-fetch and parse the SNMP data
    v2_res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", 
                      "1.3.6.1.4.1.5528.100.4.2.10.1.4",
                      "1.3.6.1.4.1.5528.100.4.2.10.1.3",
                      "1.3.6.1.4.1.5528.100.4.2.10.1.7"], mutates=False)
    
    v50_res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
                       "1.3.6.1.4.1.52674.500.4.2.10.1.4",
                       "1.3.6.1.4.1.52674.500.4.2.10.1.3",
                       "1.3.6.1.4.1.52674.500.4.2.10.1.7"], mutates=False)
    
    # Parse sensors (same logic as discovery)
    def parse_snmp_output(res, base_oid):
        if res.rc != 0:
            return []
        
        lines = res.stdout.splitlines()
        sensors_dict = {}
        
        for line in lines:
            if " = " not in line:
                continue
                
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
                
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            sensor_id = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
            
            if sensor_id not in sensors_dict:
                sensors_dict[sensor_id] = {"label": "", "error_state": "", "state_readable": ""}
            
            if base_oid == "1.3.6.1.4.1.5528.100.4.2.10.1" or base_oid == "1.3.6.1.4.1.52674.500.4.2.10.1":
                if oid_part.startswith("1.3.6.1.4.1.5528.100.4.2.10.1.4") or oid_part.startswith("1.3.6.1.4.1.52674.500.4.2.10.1.4"):
                    sensors_dict[sensor_id]["label"] = value_part.strip('"')
                elif oid_part.startswith("1.3.6.1.4.1.5528.100.4.2.10.1.3") or oid_part.startswith("1.3.6.1.4.1.52674.500.4.2.10.1.3"):
                    sensors_dict[sensor_id]["error_state"] = value_part
                elif oid_part.startswith("1.3.6.1.4.1.5528.100.4.2.10.1.7") or oid_part.startswith("1.3.6.1.4.1.52674.500.4.2.10.1.7"):
                    sensors_dict[sensor_id]["state_readable"] = value_part.strip('"')
        
        return sensors_dict.values()
    
    # Try v2 sensors first
    v2_sensors = parse_snmp_output(v2_res, "1.3.6.1.4.1.5528.100.4.2.10.1")
    v50_sensors = []
    
    if len(v2_sensors) == 0:
        v50_sensors = parse_snmp_output(v50_res, "1.3.6.1.4.1.52674.500.4.2.10.1")
        sensors = v50_sensors
    else:
        sensors = v2_sensors
    
    # Check logic: count OK sensors, report CRIT for non-OK sensors
    count_ok_sensors = 0
    crit_messages = []
    
    for sensor in sensors:
        state_readable = sensor.get("state_readable", "")
        if state_readable != "":
            error_state = sensor.get("error_state", "")
            label = sensor.get("label", "Unknown")
            
            # state_readable != "OK" means there's an issue
            if state_readable != "OK":
                state_readable_lower = state_readable.lower()
                
                # Check error state: 0 = OK, non-zero = error
                if error_state == "0":
                    count_ok_sensors += 1
                else:
                    crit_messages.append(label + ": " + state_readable_lower)
            else:
                # This sensor is OK
                if error_state == "0":
                    count_ok_sensors += 1
    
    # Build result
    if len(crit_messages) > 0:
        summary = "; ".join(crit_messages)
        if count_ok_sensors > 0:
            summary = summary + ", " + str(count_ok_sensors) + " sensors are OK"
        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }
    elif count_ok_sensors > 0:
        return {
            "changed": False,
            "msg": str(count_ok_sensors) + " sensors are OK",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
    else:
        # No sensors found or all sensors are empty
        return {
            "changed": False,
            "msg": "no numeric sensors found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
