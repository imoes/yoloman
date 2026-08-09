def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.3699.1.1.2.1.5.1.1"
        sensor_type_names = {
            "0": "undefined",
            "1": "temperature",
            "2": "humidity",
            "3": "power",
            "4": "lowVoltage",
            "5": "current",
            "6": "aclmvVoltage",
            "7": "aclmpVoltage",
            "8": "aclmpPower",
            "9": "water",
            "10": "smoke",
            "11": "vibration",
            "12": "motion",
            "13": "glass",
            "14": "door",
            "15": "keypad",
            "16": "panicButton",
            "17": "keyStation",
            "18": "digInput",
            "22": "light",
            "24": "dewpoint",
            "26": "tacDio",
            "36": "acVoltage",
            "37": "acCurrent",
            "38": "dcVoltage",
            "39": "dcCurrent",
            "41": "rmsVoltage",
            "42": "rmsCurrent",
            "43": "activePower",
            "44": "reactivePower",
            "513": "tempHum",
            "32767": "custom",
            "32769": "temperatureCombo",
            "32770": "humidityCombo",
            "540": "tempHum",
        }
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1",
            base_oid + ".2",
            base_oid + ".3",
            base_oid + ".7",
            base_oid + ".11",
            base_oid + ".12",
        ], mutates=False)
        
        lines = res.stdout.splitlines()
        sensors = {}
        for i in range(0, len(lines), 6):
            if i + 5 >= len(lines):
                continue
            
            line1 = lines[i].strip()
            line2 = lines[i+1].strip()
            line3 = lines[i+2].strip()
            line4 = lines[i+3].strip()
            line5 = lines[i+4].strip()
            line6 = lines[i+5].strip()
            
            val1 = line1.split(":")[-1].strip()
            val2 = line2.split(":")[-1].strip()
            val3 = line3.split(":")[-1].strip()
            val4 = line4.split(":")[-1].strip()
            val5 = line5.split(":")[-1].strip()
            val6 = line6.split(":")[-1].strip()
            
            if not val1.isdigit():
                continue
            
            sensor_name = val3 + " " + val1
            val4_clean = val4.replace('.','').replace('-','')
            if not val4_clean.isdigit():
                continue
            
            sensor_value = float(val4) / 10.0
            
            sensor_min = None
            sensor_max = None
            if val5.replace('.','').replace('-','').isdigit():
                sensor_min = float(val5) / 10.0
            if val6.replace('.','').replace('-','').isdigit():
                sensor_max = float(val6) / 10.0
            
            sensor_type = sensor_type_names.get(val2, "unknown")
            
            if sensor_type == "power":
                sensors[sensor_name] = {
                    "value": sensor_value,
                    "min_threshold": sensor_min,
                    "max_threshold": sensor_max,
                }
        
        out = []
        for item_name in sorted(sensors.keys()):
            out.append({
                "item": item_name,
                "params": {"levels": (15.0, 16.0), "levels_lower": (10.0, 9.0)},
                "metrics": ["voltage"],
            })
        
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(out),
            "data": {"discovery": out},
        }
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.3699.1.1.2.1.5.1.1"
    sensor_type_names = {
        "0": "undefined",
        "1": "temperature",
        "2": "humidity",
        "3": "power",
        "4": "lowVoltage",
        "5": "current",
        "6": "aclmvVoltage",
        "7": "aclmpVoltage",
        "8": "aclmpPower",
        "9": "water",
        "10": "smoke",
        "11": "vibration",
        "12": "motion",
        "13": "glass",
        "14": "door",
        "15": "keypad",
        "16": "panicButton",
        "17": "keyStation",
        "18": "digInput",
        "22": "light",
        "24": "dewpoint",
        "26": "tacDio",
        "36": "acVoltage",
        "37": "acCurrent",
        "38": "dcVoltage",
        "39": "dcCurrent",
        "41": "rmsVoltage",
        "42": "rmsCurrent",
        "43": "activePower",
        "44": "reactivePower",
        "513": "tempHum",
        "32767": "custom",
        "32769": "temperatureCombo",
        "32770": "humidityCombo",
        "540": "tempHum",
    }
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1",
        base_oid + ".2",
        base_oid + ".3",
        base_oid + ".7",
        base_oid + ".11",
        base_oid + ".12",
    ], mutates=False)
    
    lines = res.stdout.splitlines()
    sensors = {}
    for i in range(0, len(lines), 6):
        if i + 5 >= len(lines):
            continue
        
        line1 = lines[i].strip()
        line2 = lines[i+1].strip()
        line3 = lines[i+2].strip()
        line4 = lines[i+3].strip()
        line5 = lines[i+4].strip()
        line6 = lines[i+5].strip()
        
        val1 = line1.split(":")[-1].strip()
        val2 = line2.split(":")[-1].strip()
        val3 = line3.split(":")[-1].strip()
        val4 = line4.split(":")[-1].strip()
        val5 = line5.split(":")[-1].strip()
        val6 = line6.split(":")[-1].strip()
        
        if not val1.isdigit():
            continue
        
        sensor_name = val3 + " " + val1
        val4_clean = val4.replace('.','').replace('-','')
        if not val4_clean.isdigit():
            continue
        
        sensor_value = float(val4) / 10.0
        
        sensor_min = None
        sensor_max = None
        if val5.replace('.','').replace('-','').isdigit():
            sensor_min = float(val5) / 10.0
        if val6.replace('.','').replace('-','').isdigit():
            sensor_max = float(val6) / 10.0
        
        sensor_type = sensor_type_names.get(val2, "unknown")
        
        if sensor_type == "power":
            sensors[sensor_name] = {
                "value": sensor_value,
                "min_threshold": sensor_min,
                "max_threshold": sensor_max,
            }
    
    sensor = sensors.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "Sensor " + item + " not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    levels_upper = params.get("levels", (15.0, 16.0))
    levels_lower = params.get("levels_lower", (10.0, 9.0))
    
    voltage = sensor["value"]
    
    state = "OK"
    details = ""
    
    if voltage >= levels_upper[1]:
        state = "CRIT"
        details = "Voltage %f V is above critical threshold %f V" % (voltage, levels_upper[1])
    elif voltage >= levels_upper[0]:
        state = "WARN"
        details = "Voltage %f V is above warning threshold %f V" % (voltage, levels_upper[0])
    
    if state == "OK":
        if voltage <= levels_lower[1]:
            state = "CRIT"
            details = "Voltage %f V is below critical threshold %f V" % (voltage, levels_lower[1])
        elif voltage <= levels_lower[0]:
            state = "WARN"
            details = "Voltage %f V is below warning threshold %f V" % (voltage, levels_lower[0])
    
    return {
        "changed": False,
        "msg": "Voltage: %f V" % voltage,
        "data": {
            "state": state,
            "metrics": {"voltage": voltage},
            "details": details,
        },
    }
