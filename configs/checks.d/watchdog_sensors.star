def _parse_snmp_string_table(lines, base_oid):
    # Parse snmpwalk output lines like: ".1.3.6.1.4.1.21239.5.1.1.2.0 3.0.0"
    # Returns a dict mapping base_oid index -> list of values in OID order
    parsed = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        oid_parts = oid_part.rsplit(".", 1)
        if len(oid_parts) != 2:
            continue
        idx = oid_parts[1]  # last component after dot
        # Extract numeric value from value_part (strip quotes if present)
        val = value_part.strip()
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        # Group by base_oid index
        if idx not in parsed:
            parsed[idx] = []
        parsed[idx].append(val)
    return parsed


def main(ctx, params):
    if params.get("_discover"):
        # Discover sensors: walk general section and data section
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Get version info: .1.3.6.1.4.1.21239.5.1.1.2.0 and .1.3.6.1.4.1.21239.5.1.1.7.0
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.1"], mutates=False)
        if res1.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", 
                    "data": {"discovery": []}}
        
        # Get sensor data: .1.3.6.1.4.1.21239.5.1.2.1.*
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.2.1"], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", 
                    "data": {"discovery": []}}
        
        # Parse the version section
        version_data = _parse_snmp_string_table(res1.stdout.splitlines(), ".1.3.6.1.4.1.21239.5.1.1")
        general_entries = version_data.get("1", [])
        
        # Parse the sensor data section
        sensor_data = _parse_snmp_string_table(res2.stdout.splitlines(), ".1.3.6.1.4.1.21239.5.1.2.1")
        
        # Determine unit (C/F) from version section
        temp_unit = "C"  # default
        if len(general_entries) >= 2:
            unit_raw = general_entries[1]  # OID .1.3.6.1.4.1.21239.5.1.1.7.0
            if unit_raw == "0":
                temp_unit = "F"
        
        # Check version to determine parser
        version_raw = general_entries[0] if len(general_entries) >= 1 else "300"
        version = int(version_raw.replace(".", ""))
        use_legacy = version <= 300
        
        # Collect discovered items for general, temp, humidity, dew
        discovered = []
        
        # Process each sensor index
        for idx in sorted(sensor_data.keys()):
            line = sensor_data[idx]
            if len(line) < 6:
                continue
            
            sensor_id = line[0]  # first element is the OID end
            
            # General sensor (Watchdog)
            item_general = "Watchdog %s" % sensor_id
            descr = line[1]
            if use_legacy:
                avail_raw = line[3]
            else:
                avail_raw = line[2]
            avail_map = {"0": ("CRIT", "unavailable"), "1": ("OK", "available"), "2": ("WARN", "partially unavailable")}
            state, summary = avail_map.get(avail_raw, ("UNKNOWN", "unknown state"))
            
            discovered.append({"item": item_general, "params": {}, "metrics": []})
            
            # Temperature sensor
            item_temp = "Temperature %s" % sensor_id
            if use_legacy:
                temp_str = line[4]
            else:
                temp_str = line[3]
            if temp_str.isdigit():
                temp_val = int(temp_str) / 10.0
                if temp_unit == "F":
                    temp_val = (temp_val - 32) * 5.0 / 9.0
                discovered.append({"item": item_temp, "params": {}, "metrics": ["temp"]})
            
            # Humidity sensor
            item_humidity = "Humidity %s" % sensor_id
            if use_legacy:
                humidity_str = line[5]
            else:
                humidity_str = line[4]
            if humidity_str.isdigit():
                discovered.append({"item": item_humidity, "params": {"levels": (50.0, 55.0), "levels_lower": (10.0, 15.0)}, "metrics": ["humidity"]})
            
            # Dew point sensor
            item_dew = "Dew point %s" % sensor_id
            if use_legacy:
                dew_str = line[6]
            else:
                dew_str = line[5]
            if dew_str.isdigit():
                dew_val = int(dew_str) / 10.0
                if temp_unit == "F":
                    dew_val = (dew_val - 32) * 5.0 / 9.0
                discovered.append({"item": item_dew, "params": {}, "metrics": ["temp"]})
        
        return {"changed": False, "msg": "discovered %d sensors" % len(discovered),
                "data": {"discovery": discovered}}
    
    # Normal check mode (non-discovery)
    item = params.get("item", "")
    
    # Detect type by item prefix
    if item.startswith("Watchdog "):
        # General sensor check
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.1"], mutates=False)
        if res1.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.2.1"], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        # Parse version section
        version_data = _parse_snmp_string_table(res1.stdout.splitlines(), ".1.3.6.1.4.1.21239.5.1.1")
        general_entries = version_data.get("1", [])
        temp_unit = "C"
        if len(general_entries) >= 2:
            unit_raw = general_entries[1]
            if unit_raw == "0":
                temp_unit = "F"
        
        version_raw = general_entries[0] if len(general_entries) >= 1 else "300"
        version = int(version_raw.replace(".", ""))
        use_legacy = version <= 300
        
        # Parse sensor data
        sensor_data = _parse_snmp_string_table(res2.stdout.splitlines(), ".1.3.6.1.4.1.21239.5.1.2.1")
        
        # Find our sensor
        sensor_id = item.replace("Watchdog ", "")
        line = sensor_data.get(sensor_id, [])
        
        if len(line) < (7 if use_legacy else 6):
            return {"changed": False, "msg": "sensor %s not found" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        descr = line[1]
        avail_raw = line[3] if use_legacy else line[2]
        avail_map = {"0": ("CRIT", "unavailable"), "1": ("OK", "available"), "2": ("WARN", "partially unavailable")}
        state, summary = avail_map.get(avail_raw, ("UNKNOWN", "unknown state"))
        
        full_summary = summary
        if descr != "":
            full_summary = "%s, Location: %s" % (summary, descr)
        
        return {"changed": False, "msg": full_summary,
                "data": {"state": state, "metrics": {}, "details": ""}}
    
    elif item.startswith("Temperature "):
        # Temperature check
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.1"], mutates=False)
        if res1.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.2.1"], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        # Parse version
        version_data = _parse_snmp_string_table(res1.stdout.splitlines(), ".1.3.6.1.4.1.21239.5.1.1")
        general_entries = version_data.get("1", [])
        temp_unit = "C"
        if len(general_entries) >= 2:
            unit_raw = general_entries[1]
            if unit_raw == "0":
                temp_unit = "F"
        
        version_raw = general_entries[0] if len(general_entries) >= 1 else "300"
        version = int(version_raw.replace(".", ""))
        use_legacy = version <= 300
        
        # Parse sensor data
        sensor_data = _parse_snmp_string_table(res2.stdout.splitlines(), ".1.3.6.1.4.1.21239.5.1.2.1")
        
        sensor_id = item.replace("Temperature ", "")
        line = sensor_data.get(sensor_id, [])
        
        if len(line) < (5 if use_legacy else 4):
            return {"changed": False, "msg": "sensor %s not found" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        temp_str = line[4] if use_legacy else line[3]
        if not temp_str.isdigit():
            return {"changed": False, "msg": "invalid temperature value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        temp_val = int(temp_str) / 10.0
        if temp_unit == "F":
            temp_val = (temp_val - 32) * 5.0 / 9.0
        
        # Threshold defaults
        warn = params.get("levels", (25.0, 30.0))
        crit = params.get("levels", (30.0, 35.0))
        # Checkmk temp params: warn=(upper, lower), crit=(upper, lower)
        warn_upper = warn[0]
        crit_upper = crit[0]
        
        state = "OK"
        if temp_val >= crit_upper:
            state = "CRIT"
        elif temp_val >= warn_upper:
            state = "WARN"
        
        summary = "%f C" % temp_val
        if state != "OK":
            summary = summary + " (warn/crit at %f/%f C)" % (warn_upper, crit_upper)
        
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": {"temp": temp_val}, "details": ""}}
    
    elif item.startswith("Humidity "):
        # Humidity check
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.1"], mutates=False)
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.2.1"], mutates=False)
        if res1.rc != 0 or res2.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        # Parse sensor data
        sensor_data = _parse_snmp_string_table(res2.stdout.splitlines(), ".1.3.6.1.4.1.21239.5.1.2.1")
        
        sensor_id = item.replace("Humidity ", "")
        line = sensor_data.get(sensor_id, [])
        
        if len(line) < (6 if line else 5):
            return {"changed": False, "msg": "sensor %s not found" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        humidity_str = line[5] if len(line) > 5 else line[4]
        if not humidity_str.isdigit():
            return {"changed": False, "msg": "invalid humidity value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        humidity = int(humidity_str)
        
        # Get thresholds
        levels = params.get("levels", (50.0, 55.0))
        levels_lower = params.get("levels_lower", (10.0, 15.0))
        warn_upper = levels[0]
        crit_upper = levels[1]
        warn_lower = levels_lower[0]
        crit_lower = levels_lower[1]
        
        state = "OK"
        if humidity >= crit_upper or humidity <= crit_lower:
            state = "CRIT"
        elif humidity >= warn_upper or humidity <= warn_lower:
            state = "WARN"
        
        summary = "%f%%" % humidity
        if humidity >= warn_upper:
            summary = summary + " (warn/crit at %f/%f%%)" % (warn_upper, crit_upper)
        elif humidity <= warn_lower:
            summary = summary + " (warn/crit below %f/%f%%)" % (warn_lower, crit_lower)
        
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": {"humidity": humidity}, "details": ""}}
    
    elif item.startswith("Dew point "):
        # Dew point check (same logic as temperature)
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.1"], mutates=False)
        if res1.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21239.5.1.2.1"], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        # Parse version
        version_data = _parse_snmp_string_table(res1.stdout.splitlines(), ".1.3.6.1.4.1.21239.5.1.1")
        general_entries = version_data.get("1", [])
        temp_unit = "C"
        if len(general_entries) >= 2:
            unit_raw = general_entries[1]
            if unit_raw == "0":
                temp_unit = "F"
        
        version_raw = general_entries[0] if len(general_entries) >= 1 else "300"
        version = int(version_raw.replace(".", ""))
        use_legacy = version <= 300
        
        # Parse sensor data
        sensor_data = _parse_snmp_string_table(res2.stdout.splitlines(), ".1.3.6.1.4.1.21239.5.1.2.1")
        
        sensor_id = item.replace("Dew point ", "")
        line = sensor_data.get(sensor_id, [])
        
        if len(line) < (7 if use_legacy else 6):
            return {"changed": False, "msg": "sensor %s not found" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        dew_str = line[6] if use_legacy else line[5]
        if not dew_str.isdigit():
            return {"changed": False, "msg": "invalid dew point value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        dew_val = int(dew_str) / 10.0
        if temp_unit == "F":
            dew_val = (dew_val - 32) * 5.0 / 9.0
        
        # Threshold defaults (same as temperature)
        warn = params.get("levels", (25.0, 30.0))
        crit = params.get("levels", (30.0, 35.0))
        warn_upper = warn[0]
        crit_upper = crit[0]
        
        state = "OK"
        if dew_val >= crit_upper:
            state = "CRIT"
        elif dew_val >= warn_upper:
            state = "WARN"
        
        summary = "%f C" % dew_val
        if state != "OK":
            summary = summary + " (warn/crit at %f/%f C)" % (warn_upper, crit_upper)
        
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": {"temp": dew_val}, "details": ""}}
    
    else:
        return {"changed": False, "msg": "unknown sensor type",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}