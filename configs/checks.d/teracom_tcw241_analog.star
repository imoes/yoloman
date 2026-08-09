def main(ctx, params):
    # Discovery mode: enumerate analog sensors
    if params.get("_discover"):
        out = []
        for table in ["1", "2", "3", "4"]:
            base = ".1.3.6.1.4.1.38783.3.2.2.2." + table
            desc_res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"),
                base + ".1"
            ], mutates=False)
            max_res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"),
                base + ".2"
            ], mutates=False)
            min_res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"),
                base + ".3"
            ], mutates=False)
            
            desc = _parse_snmp_scalar(desc_res.stdout)
            maximum = _parse_snmp_scalar(max_res.stdout)
            minimum = _parse_snmp_scalar(min_res.stdout)
            
            if desc == None or desc == "":
                continue
            if maximum == None or maximum == "":
                continue
            if minimum == None or minimum == "":
                continue
            
            out.append({
                "item": table,
                "params": {},
                "metrics": ["voltage"],
                "description": desc,
                "maximum": maximum,
                "minimum": minimum,
            })
        
        voltage_res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.38783.3.3.2"
        ], mutates=False)
        voltages = _parse_snmp_scalar_multi(voltage_res.stdout, 4)
        
        filtered = []
        for sens in out:
            item = sens["item"]
            v_idx = int(item) - 1
            if v_idx >= 0 and v_idx < len(voltages) and voltages[v_idx] != None:
                volt_str = voltages[v_idx]
                if volt_str.isdigit() or (volt_str.startswith("-") and volt_str[1:].isdigit()):
                    sens["voltage"] = str(float(volt_str) / 1000.0)
                else:
                    continue
            else:
                continue
            
            min_str = sens["minimum"]
            max_str = sens["maximum"]
            min_val = float(min_str) if min_str.isdigit() or (min_str.startswith("-") and min_str[1:].isdigit()) else 0
            max_val = float(max_str) if max_str.isdigit() or (max_str.startswith("-") and max_str[1:].isdigit()) else 0
            
            if min_val < 1 or max_val < 1:
                continue
            
            filtered.append({
                "item": sens["item"],
                "params": {},
                "metrics": ["voltage"],
            })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(filtered),
            "data": {"discovery": filtered},
        }
    
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    base = ".1.3.6.1.4.1.38783.3.2.2.2." + item
    desc_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base + ".1"
    ], mutates=False)
    max_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base + ".2"
    ], mutates=False)
    min_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        base + ".3"
    ], mutates=False)
    
    volt_oid = ".1.3.6.1.4.1.38783.3.3.2." + item + ".0"
    volt_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        volt_oid
    ], mutates=False)
    
    description = _parse_snmp_scalar(desc_res.stdout)
    maximum = _parse_snmp_scalar(max_res.stdout)
    minimum = _parse_snmp_scalar(min_res.stdout)
    voltage_str = _parse_snmp_scalar(volt_res.stdout)
    
    if description == None or description == "":
        return {
            "changed": False,
            "msg": "sensor not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Validate strings can be converted
    def to_float_safe(s):
        if s == None:
            return None
        stripped = s.strip()
        if stripped == "":
            return None
        if stripped.isdigit():
            return float(stripped)
        if stripped.startswith("-") and len(stripped) > 1:
            if stripped[1:].isdigit():
                return float(stripped)
        return None
    
    sensor_maximum = to_float_safe(maximum)
    sensor_minimum = to_float_safe(minimum)
    sensor_voltage = None
    if voltage_str != None:
        sensor_voltage = to_float_safe(voltage_str)
    
    if sensor_minimum == None or sensor_maximum == None:
        return {
            "changed": False,
            "msg": "invalid sensor data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    sensor_maximum = sensor_maximum / 1000.0
    sensor_minimum = sensor_minimum / 1000.0
    
    if sensor_minimum < 1 or sensor_maximum < 1:
        return {
            "changed": False,
            "msg": "invalid thresholds",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    if sensor_voltage == None:
        return {
            "changed": False,
            "msg": "no voltage reading",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    sensor_voltage = sensor_voltage / 1000.0
    
    state = "OK"
    if sensor_voltage < sensor_minimum or sensor_voltage > sensor_maximum:
        state = "CRIT"
    
    label = "[" + description + "]"
    msg = "%s %f V" % (label, sensor_voltage)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"voltage": sensor_voltage},
            "details": "",
        },
    }


def _parse_snmp_scalar(output):
    if output == None or output == "":
        return None
    lines = output.splitlines()
    if len(lines) == 0:
        return None
    line = lines[0].strip()
    idx = line.find(" = ")
    if idx == -1:
        idx = line.find(": ")
    if idx == -1:
        return None
    value_str = line[idx+2:].strip()
    return value_str


def _parse_snmp_scalar_multi(output, count):
    res = []
    if output == None:
        return res
    lines = output.splitlines()
    for i in range(count):
        if i < len(lines):
            val = _parse_snmp_scalar(lines[i])
            res.append(val)
        else:
            res.append(None)
    return res