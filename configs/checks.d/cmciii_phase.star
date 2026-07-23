def main(ctx, params):
    if params.get("_discover"):
        # DISCOVERY MODE
        # Get base OID for phase sensors
        base_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            base_oid
        ], mutates=False)
        
        phases = {}
        if res.rc == 0:
            # Parse SNMP output
            for line in res.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_str = parts[0].strip()
                value_str = parts[1].strip()
                
                if not oid_str.startswith(base_oid + "."):
                    continue
                
                suffix = oid_str[len(base_oid) + 1:]
                dot_pos = suffix.find(".")
                if dot_pos == -1:
                    continue
                index = suffix[:dot_pos]
                field = suffix[dot_pos + 1:]
                
                # Extract value
                if ": " in value_str:
                    value = value_str.split(": ", 1)[1].strip().strip('"')
                else:
                    value = value_str.strip().strip('"')
                
                if index not in phases:
                    phases[index] = {"_index_": index}
                
                # Map field numbers to names
                field_map = {
                    "6": "DescName",
                    "10": "Current",
                    "20": "Voltage_L1_N",
                    "21": "Voltage_L2_N",
                    "22": "Voltage_L3_N",
                    "30": "Power",
                    "35": "Power_factor",
                    "40": "Frequency",
                    "31": "Apparent_power",
                    "32": "Reactive_power",
                }
                
                if field in field_map:
                    name = field_map[field]
                    # Convert to float if numeric string, otherwise keep as string
                    if value.lstrip("-").replace(".", "", 1).isdigit():
                        phases[index][name] = float(value)
                    else:
                        phases[index][name] = value
        
        # Build discovery list
        discovery = []
        for index, phase in phases.items():
            item = index
            if params.get("use_sensor_description", False):
                location = phase.get("_location_", "")
                index_num = phase.get("_index_", index)
                desc = phase.get("DescName", "")
                item = "%s-%s %s" % (location, index_num, desc)
            
            # Default metrics based on available data
            metrics = []
            if "Current" in phase:
                metrics.append("current")
            if "Voltage_L1_N" in phase:
                metrics.extend(["voltage_l1_n", "voltage_l2_n", "voltage_l3_n"])
            if "Power" in phase:
                metrics.append("power")
            if "Power_factor" in phase:
                metrics.append("power_factor")
            if "Frequency" in phase:
                metrics.append("frequency")
            
            discovery.append({
                "item": item,
                "params": {"_item_key": index},
                "metrics": metrics
            })
        
        return {
            "changed": False,
            "msg": "discovered %d phase sensors" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # CHECK MODE
    item = params.get("item", "")
    
    # Get phase data
    base_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        base_oid
    ], mutates=False)
    
    phases = {}
    if res.rc == 0:
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_str = parts[0].strip()
            value_str = parts[1].strip()
            
            if not oid_str.startswith(base_oid + "."):
                continue
            
            suffix = oid_str[len(base_oid) + 1:]
            dot_pos = suffix.find(".")
            if dot_pos == -1:
                continue
            index = suffix[:dot_pos]
            field = suffix[dot_pos + 1:]
            
            if ": " in value_str:
                value = value_str.split(": ", 1)[1].strip().strip('"')
            else:
                value = value_str.strip().strip('"')
            
            if index not in phases:
                phases[index] = {"_index_": index}
            
            field_map = {
                "6": "DescName",
                "10": "Current",
                "20": "Voltage_L1_N",
                "21": "Voltage_L2_N",
                "22": "Voltage_L3_N",
                "30": "Power",
                "35": "Power_factor",
                "40": "Frequency",
                "31": "Apparent_power",
                "32": "Reactive_power",
            }
            
            if field in field_map:
                name = field_map[field]
                if value.lstrip("-").replace(".", "", 1).isdigit():
                    phases[index][name] = float(value)
                else:
                    phases[index][name] = value
    
    # Find the requested phase - use _item_key for compatibility
    sensor = None
    sensor_key = params.get("_item_key", "")
    if sensor_key and sensor_key in phases:
        sensor = phases[sensor_key]
    elif item in phases:
        sensor = phases[item]
    
    # Item not found -> UNKNOWN
    if sensor == None:
        return {
            "changed": False,
            "msg": "phase sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract threshold parameters (Checkmk defaults)
    warn = params.get("current_warn", None)
    crit = params.get("current_crit", None)
    warn_voltage = params.get("voltage_warn", None)
    crit_voltage = params.get("voltage_crit", None)
    warn_freq = params.get("frequency_warn", None)
    crit_freq = params.get("frequency_crit", None)
    
    # Determine state and build metrics
    state = "OK"
    metrics = {}
    details_parts = []
    
    # Current metrics
    if "Current" in sensor:
        current = sensor["Current"]
        if type(current) == "float" or type(current) == "int":
            metrics["current"] = current
            details_parts.append("Current: %f A" % current)
            if crit != None and current >= crit:
                state = "CRIT"
            elif warn != None and current >= warn:
                if state == "OK":
                    state = "WARN"
    
    # Voltage metrics
    if "Voltage_L1_N" in sensor:
        voltage_l1 = sensor["Voltage_L1_N"]
        if type(voltage_l1) == "float" or type(voltage_l1) == "int":
            metrics["voltage_l1_n"] = voltage_l1
            if crit_voltage != None and voltage_l1 >= crit_voltage:
                state = "CRIT"
            elif warn_voltage != None and voltage_l1 >= warn_voltage:
                if state == "OK":
                    state = "WARN"
    
    if "Voltage_L2_N" in sensor:
        metrics["voltage_l2_n"] = sensor["Voltage_L2_N"]
    if "Voltage_L3_N" in sensor:
        metrics["voltage_l3_n"] = sensor["Voltage_L3_N"]
    
    # Power metrics
    if "Power" in sensor:
        power = sensor["Power"]
        if type(power) == "float" or type(power) == "int":
            metrics["power"] = power
            details_parts.append("Power: %f W" % power)
    
    # Frequency metrics
    if "Frequency" in sensor:
        freq = sensor["Frequency"]
        if type(freq) == "float" or type(freq) == "int":
            metrics["frequency"] = freq
            details_parts.append("Frequency: %f Hz" % freq)
            if crit_freq != None and freq >= crit_freq:
                state = "CRIT"
            elif warn_freq != None and freq >= warn_freq:
                if state == "OK":
                    state = "WARN"
    
    # Power factor
    if "Power_factor" in sensor:
        pf = sensor["Power_factor"]
        if type(pf) == "float" or type(pf) == "int":
            metrics["power_factor"] = pf
    
    # Apparent power
    if "Apparent_power" in sensor:
        metrics["apparent_power"] = sensor["Apparent_power"]
    
    # Reactive power
    if "Reactive_power" in sensor:
        metrics["reactive_power"] = sensor["Reactive_power"]
    
    # Build message
    msg = item
    if details_parts:
        msg = item + " - " + ", ".join(details_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
