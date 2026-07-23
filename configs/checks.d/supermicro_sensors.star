def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.10876.2.1.1.1.1"
    
    def walk_section(oid_base):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            oid_base
        ], mutates=False)
        if res.rc != 0:
            return []
        return res.stdout.splitlines()
    
    def parse_snmp_line(line):
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            return None, None
        oid = parts[0].strip()
        value_part = parts[1].strip()
        if value_part.startswith("STRING: "):
            return oid, value_part[8:].strip('"')
        elif value_part.startswith("INTEGER: "):
            return oid, value_part[9:]
        elif value_part.startswith("Gauge32: "):
            return oid, value_part[9:]
        elif value_part.startswith("Counter32: "):
            return oid, value_part[11:]
        else:
            return oid, value_part.strip('"')
    
    if params.get("_discover"):
        lines = walk_section(base_oid)
        sensors = {}
        for line in lines:
            oid, value = parse_snmp_line(line)
            if oid == None:
                continue
            if not oid.startswith(base_oid):
                continue
            idx = oid.rsplit(".", 1)[-1]
            if not idx.isdigit():
                continue
            if oid.endswith(".2"):
                sensors[idx] = {"name": value, "type_oid": None, "reading_oid": None,
                                "high_oid": None, "low_oid": None, "unit_oid": None, "status_oid": None}
        
        for line in lines:
            oid, value = parse_snmp_line(line)
            if oid == None:
                continue
            if not oid.startswith(base_oid):
                continue
            idx = oid.rsplit(".", 1)[-1]
            if not idx.isdigit():
                continue
            if oid.endswith(".3") and idx in sensors:
                sensors[idx]["type_oid"] = value
            elif oid.endswith(".4") and idx in sensors:
                sensors[idx]["reading_oid"] = value
            elif oid.endswith(".5") and idx in sensors:
                sensors[idx]["high_oid"] = value
            elif oid.endswith(".6") and idx in sensors:
                sensors[idx]["low_oid"] = value
            elif oid.endswith(".11") and idx in sensors:
                sensors[idx]["unit_oid"] = value
            elif oid.endswith(".12") and idx in sensors:
                sensors[idx]["status_oid"] = value
        
        discovery_list = []
        for idx, sensor in sensors.items():
            if sensor.get("name"):
                suggested_params = {}
                high = sensor.get("high_oid")
                if high != None and high.replace(".", "").replace("-", "").isdigit():
                    crit_upper = float(high)
                    suggested_params["upper_levels"] = (crit_upper * 0.95, crit_upper)
                low = sensor.get("low_oid")
                if low != None and low.replace(".", "").replace("-", "").isdigit():
                    crit_lower = float(low)
                    suggested_params["lower_levels"] = (crit_lower, crit_lower * 1.05)
                
                metric_name = None
                sensor_type = sensor.get("type_oid")
                if sensor_type == "2":
                    metric_name = "temp"
                elif sensor_type == "1":
                    metric_name = "voltage"
                
                metrics = [metric_name] if metric_name else []
                discovery_list.append({
                    "item": sensor["name"],
                    "params": suggested_params,
                    "metrics": metrics
                })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    item = params.get("item", "")
    lines = walk_section(base_oid)
    
    sensors = {}
    for line in lines:
        oid, value = parse_snmp_line(line)
        if oid == None:
            continue
        if not oid.startswith(base_oid):
            continue
        idx = oid.rsplit(".", 1)[-1]
        if not idx.isdigit():
            continue
        if oid.endswith(".2"):
            sensors[idx] = {"name": value}
        elif idx in sensors:
            if oid.endswith(".3"):
                sensors[idx]["type_oid"] = value
            elif oid.endswith(".4"):
                sensors[idx]["reading_oid"] = value
            elif oid.endswith(".5"):
                sensors[idx]["high_oid"] = value
            elif oid.endswith(".6"):
                sensors[idx]["low_oid"] = value
            elif oid.endswith(".11"):
                sensors[idx]["unit_oid"] = value
            elif oid.endswith(".12"):
                sensors[idx]["status_oid"] = value
    
    found = False
    for idx, sensor in sensors.items():
        if sensor.get("name") == item:
            found = True
            reading_str = sensor.get("reading_oid", "")
            if reading_str == "" or not (reading_str.replace(".", "").replace("-", "").isdigit() or reading_str.isdigit()):
                reading = 0.0
            else:
                reading = float(reading_str)
            
            sensor_type = sensor.get("type_oid", "")
            status_str = sensor.get("status_oid", "0")
            status = int(status_str) if status_str.isdigit() else 3
            
            order = [0, 1, 3, 2]
            worst = sorted([status], key=lambda x: order[x], reverse=True)[0]
            status_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
            state = status_map.get(worst, "UNKNOWN")
            
            unit = sensor.get("unit_oid", "")
            display_reading = reading
            perfvar = None
            
            if sensor_type == "2":
                unit = "\u00b0" + unit
                perfvar = "temp"
            elif sensor_type == "1":
                if unit == "mV":
                    reading = reading / 1000.0
                    display_reading = reading
                    unit = "V"
                perfvar = "voltage"
            elif sensor_type == "3":
                display_reading = "State " + str(int(reading))
                unit = ""
            
            high = sensor.get("high_oid")
            low = sensor.get("low_oid")
            if high != None and high.replace(".", "").replace("-", "").isdigit():
                crit_upper = float(high)
                warn_upper = crit_upper * 0.95
                if reading >= crit_upper:
                    state = "CRIT"
                elif reading >= warn_upper and state != "CRIT":
                    state = "WARN"
            if low != None and low.replace(".", "").replace("-", "").isdigit():
                crit_lower = float(low)
                warn_lower = crit_lower * 1.05
                if reading <= crit_lower:
                    state = "CRIT"
                elif reading <= warn_lower and state != "CRIT":
                    state = "WARN"
            
            upper_levels = params.get("upper_levels")
            if upper_levels != None:
                warn_u, crit_u = upper_levels
                if reading >= crit_u:
                    state = "CRIT"
                elif reading >= warn_u and state != "CRIT":
                    state = "WARN"
            lower_levels = params.get("lower_levels")
            if lower_levels != None:
                crit_l, warn_l = lower_levels
                if reading <= crit_l:
                    state = "CRIT"
                elif reading <= warn_l and state != "CRIT":
                    state = "WARN"
            
            summary = "%s%s" % (str(display_reading), unit)
            metrics = {}
            if perfvar:
                metrics[perfvar] = reading
            if perfvar == "temp":
                metrics["temp"] = reading
            if perfvar == "voltage":
                metrics["voltage"] = reading
            
            return {
                "changed": False,
                "msg": summary,
                "data": {
                    "state": state,
                    "metrics": metrics,
                    "details": ""
                }
            }
    
    if not found:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }