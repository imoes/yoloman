def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.20916.1.8.1.1"
    
    # Discovery mode: enumerate items this host has
    if params.get("_discover"):
        # Fetch internal sensors (temperature, humidity, heat index)
        internal_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1",  # temperature
            base_oid + ".2",  # humidity
            base_oid + ".4.2" # heat index
        ], mutates=False)
        
        internal = _parse_internal_snmp(internal_res.stdout)
        
        # Fetch digital sensor blocks (8 possible)
        digital_sections = []
        for i in range(1, 9):
            # For each digital sensor, we fetch the full block of OIDs
            block_res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On", host,
                ".1.3.6.1.4.1.20916.1.8.1.2." + str(i) + ".1",  # temp (C)
                ".1.3.6.1.4.1.20916.1.8.1.2." + str(i) + ".3",  # humidity/voltage/power
                ".1.3.6.1.4.1.20916.1.8.1.2." + str(i) + ".5"   # heat index (C)
            ], mutates=False)
            sec = _parse_digital_snmp(block_res.stdout, i - 1)
            digital_sections.append(sec)
        
        out = []
        # Internal services
        if internal.temperature != None:
            out.append({
                "item": "Internal",
                "params": {"levels": [30.0, 35.0]},
                "metrics": ["temperature"]
            })
            out.append({
                "item": "Heat Index",
                "params": {"levels": [30.0, 35.0]},
                "metrics": ["temperature"]
            })
        
        # Digital sensor services
        for i, sec in enumerate(digital_sections):
            if sec == None:
                continue
            if sec.temperature != None:
                out.append({
                    "item": "Sensor " + str(i + 1),
                    "params": {"levels": [30.0, 35.0]},
                    "metrics": ["temperature"]
                })
            if sec.humidity != None:
                out.append({
                    "item": "Sensor " + str(i + 1),
                    "params": {"levels": [70.0, 80.0]},
                    "metrics": ["humidity"]
                })
            if sec.voltage != None:
                out.append({
                    "item": "Sensor " + str(i + 1),
                    "params": {"voltage": [210, 180]},
                    "metrics": ["voltage"]
                })
            if sec.power != None:
                out.append({
                    "item": "Sensor " + str(i + 1),
                    "params": {},
                    "metrics": ["power_state"]
                })
            if sec.heat_index != None:
                out.append({
                    "item": "Heat Index " + str(i + 1),
                    "params": {"levels": [30.0, 35.0]},
                    "metrics": ["temperature"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d services" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode: handle one item
    item = params.get("item", "")
    
    # Fetch internal and digital data again for this check
    internal_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1",
        base_oid + ".2",
        base_oid + ".4.2"
    ], mutates=False)
    internal = _parse_internal_snmp(internal_res.stdout)
    
    digital_sections = []
    for i in range(1, 9):
        block_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.20916.1.8.1.2." + str(i) + ".1",
            ".1.3.6.1.4.1.20916.1.8.1.2." + str(i) + ".3",
            ".1.3.6.1.4.1.20916.1.8.1.2." + str(i) + ".5"
        ], mutates=False)
        digital_sections.append(_parse_digital_snmp(block_res.stdout, i - 1))
    
    # Internal checks
    if item == "Internal" or item == "Heat Index":
        if internal == None or (item == "Heat Index" and internal.heat_index == None):
            return {
                "changed": False,
                "msg": "no %s data available" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        # Apply temperature thresholds
        value = internal.heat_index if item == "Heat Index" else internal.temperature
        warn = params.get("levels", [30.0, 35.0])
        if type(warn) == "list":
            warn_val = float(warn[0])
            crit_val = float(warn[1])
        else:
            warn_val = 30.0
            crit_val = 35.0
        
        state = "OK"
        msg_parts = ["Temperature: %f C" % value]
        if value >= crit_val:
            state = "CRIT"
            msg_parts[0] += " (critical!)"
        elif value >= warn_val:
            state = "WARN"
            msg_parts[0] += " (warning!)"
        
        return {
            "changed": False,
            "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {"temperature": value}, "details": ""}
        }
    
    # Digital sensor checks
    index = None
    if item.startswith("Sensor "):
        parts = item.split()
        if len(parts) == 2:
            idx_val = parts[1]
            if idx_val.isdigit():
                idx = int(idx_val) - 1
                if (0 <= idx) and (idx <= 7):
                    index = idx
    elif item.startswith("Heat Index "):
        parts = item.split()
        if len(parts) == 3:
            idx_val = parts[2]
            if idx_val.isdigit():
                idx = int(idx_val) - 1
                if (0 <= idx) and (idx <= 7):
                    index = idx
                    item = "Heat Index " + str(idx + 1)
    
    if index == None:
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    sec = digital_sections[index]
    if sec == None:
        return {
            "changed": False,
            "msg": "sensor %d not available" % (index + 1),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Temperature
    if item == "Sensor " + str(index + 1) or item == "Heat Index " + str(index + 1):
        value = sec.heat_index if item.startswith("Heat Index") else sec.temperature
        if value == None:
            return {
                "changed": False,
                "msg": "no temperature on %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        warn = params.get("levels", [30.0, 35.0])
        if type(warn) == "list":
            warn_val = float(warn[0])
            crit_val = float(warn[1])
        else:
            warn_val = 30.0
            crit_val = 35.0
        
        state = "OK"
        msg_parts = ["Temperature: %f C" % value]
        if value >= crit_val:
            state = "CRIT"
            msg_parts[0] += " (critical!)"
        elif value >= warn_val:
            state = "WARN"
            msg_parts[0] += " (warning!)"
        
        return {
            "changed": False,
            "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {"temperature": value}, "details": ""}
        }
    
    # Humidity
    if item == "Sensor " + str(index + 1):
        if sec.humidity == None:
            return {
                "changed": False,
                "msg": "no humidity sensor on %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        warn = params.get("levels", [70.0, 80.0])
        if type(warn) == "list":
            warn_val = float(warn[0])
            crit_val = float(warn[1])
        else:
            warn_val = 70.0
            crit_val = 80.0
        
        state = "OK"
        msg_parts = ["Humidity: %f%%" % sec.humidity]
        if sec.humidity >= crit_val:
            state = "CRIT"
            msg_parts[0] += " (critical!)"
        elif sec.humidity >= warn_val:
            state = "WARN"
            msg_parts[0] += " (warning!)"
        
        return {
            "changed": False,
            "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {"humidity": sec.humidity}, "details": ""}
        }
    
    # Voltage
    if item == "Sensor " + str(index + 1):
        if sec.voltage == None:
            return {
                "changed": False,
                "msg": "no voltage sensor on %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        voltage_params = params.get("voltage", [210, 180])
        if type(voltage_params) == "list":
            warn_val = float(voltage_params[0])
            crit_val = float(voltage_params[1])
        else:
            warn_val = 210
            crit_val = 180
        
        state = "OK"
        msg_parts = ["Voltage: %d V" % sec.voltage]
        if sec.voltage <= crit_val:
            state = "CRIT"
            msg_parts[0] += " (critical!)"
        elif sec.voltage <= warn_val:
            state = "WARN"
            msg_parts[0] += " (warning!)"
        
        return {
            "changed": False,
            "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {"voltage": sec.voltage}, "details": ""}
        }
    
    # Power state
    if item == "Sensor " + str(index + 1):
        if sec.power == None:
            return {
                "changed": False,
                "msg": "no power sensor on %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        state = "OK" if sec.power else "CRIT"
        msg = "Power OK" if sec.power else "No power detected"
        
        return {
            "changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": {"power_state": 1 if sec.power else 0}, "details": ""}
        }
    
    # Fallback
    return {
        "changed": False,
        "msg": "unknown item type: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }


# Parse internal section from SNMP walk output
def _parse_internal_snmp(output):
    temp = None
    humidity = None
    heat_index = None
    
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        # OID format: .1.3.6.1.4.1.20916.1.8.1.1.1.0 = INTEGER: 2450
        if line.find(".1.3.6.1.4.1.20916.1.8.1.1.1.") != -1:
            parts = line.split("=")
            if len(parts) == 2:
                val_str = parts[1].strip().split(":")[1].strip()
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    temp = float(val_str) / 100.0
        elif line.find(".1.3.6.1.4.1.20916.1.8.1.1.2.") != -1:
            parts = line.split("=")
            if len(parts) == 2:
                val_str = parts[1].strip().split(":")[1].strip()
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    humidity = float(val_str) / 100.0
        elif line.find(".1.3.6.1.4.1.20916.1.8.1.1.4.2") != -1:
            parts = line.split("=")
            if len(parts) == 2:
                val_str = parts[1].strip().split(":")[1].strip()
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    heat_index = float(val_str) / 100.0
    
    if temp == None and humidity == None and heat_index == None:
        return None
    return {
        "temperature": temp,
        "humidity": humidity,
        "heat_index": heat_index
    }


# Parse digital sensor section from SNMP walk output
def _parse_digital_snmp(output, index):
    temperature = None
    humidity = None
    voltage = None
    power = None
    heat_index = None
    
    lines = output.splitlines()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split("=")
        if len(parts) != 2:
            continue
        
        oid = parts[0].strip()
        val_str = parts[1].strip()
        
        # Extract value after colon
        if val_str.find(":") != -1:
            val_str = val_str.split(":")[1].strip()
        else:
            continue
        
        # Try parsing temperature (C)
        if oid.endswith(".1"):
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                temperature = float(val_str) / 100.0
        
        # Try parsing .3 (humidity/voltage/power)
        elif oid.endswith(".3"):
            val = float(val_str)
            if (val >= 0.0) and (val <= 100.0) and humidity == None:
                humidity = val / 100.0
            elif val_str == "0" or val_str == "1":
                power = (val_str == "1")
            else:
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    voltage = int(float(val_str))
        
        # Try parsing .5 (heat index C)
        elif oid.endswith(".5"):
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                heat_index = float(val_str) / 100.0
    
    if temperature == None and humidity == None and voltage == None and power == None and heat_index == None:
        return None
    return {
        "temperature": temperature,
        "humidity": humidity,
        "voltage": voltage,
        "power": power,
        "heat_index": heat_index
    }