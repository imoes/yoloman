def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        base_oid = ".1.3.6.1.4.1.13595.2.2.3.1"
        
        res_value = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid + ".7"
        ], mutates=False)
        
        sensor_locations = {}
        for line in res_value.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            if value_part.startswith("INTEGER:"):
                value_str = value_part.split(":")[1].strip()
                if value_str.isdigit():
                    location = oid_part.rsplit(".", 1)[-1]
                    sensor_locations[location] = {
                        "value": int(value_str),
                        "oid": oid_part
                    }
        
        res_levels = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid + ".18"
        ], mutates=False)
        
        sensor_volt_entries = []
        for line in res_levels.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            if value_part.startswith("STRING:") or value_part.startswith("OCTETSTRING:"):
                equation_str = value_part.split(":", 1)[1].strip().strip('"')
                if equation_str == "":
                    continue
                
                equation_parts = []
                current_part = []
                for i in range(len(equation_str)):
                    char = equation_str[i]
                    if char == '\x00':
                        if current_part:
                            equation_parts.append("".join(current_part))
                            current_part = []
                    else:
                        current_part.append(char)
                if current_part:
                    equation_parts.append("".join(current_part))
                
                if len(equation_parts) >= 2:
                    unit_indicator = equation_parts[0]
                    if "mV" in unit_indicator or ("#" in unit_indicator and "m" in unit_indicator):
                        eq_str = equation_parts[1]
                        eq_str = eq_str.replace("-", "+-").split("+")
                        if len(eq_str) == 2:
                            mult_str = eq_str[0]
                            off_str = eq_str[1]
                            if mult_str.replace('.', '', 1).replace('-', '', 1).isdigit() and off_str.replace('.', '', 1).replace('-', '', 1).isdigit():
                                multiplier = float(mult_str)
                                offset = float(off_str)
                            else:
                                multiplier = 1.0
                                offset = 0.0
                        elif len(eq_str) == 1:
                            mult_str = eq_str[0]
                            if mult_str.replace('.', '', 1).replace('-', '', 1).isdigit():
                                multiplier = float(mult_str)
                            else:
                                multiplier = 1.0
                            offset = 0.0
                        else:
                            multiplier = 1.0
                            offset = 0.0
                        
                        location = oid_part.rsplit(".", 1)[-1]
                        if location in sensor_locations:
                            sensor_volt_entries.append({
                                "item": "Phase " + location,
                                "params": {},
                                "metrics": ["voltage"]
                            })
        
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(sensor_volt_entries),
            "data": {
                "discovery": sensor_volt_entries
            }
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    location = item[6:] if item.startswith("Phase ") else item
    
    base_oid = ".1.3.6.1.4.1.13595.2.2.3.1"
    
    res_value = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid + ".7"
    ], mutates=False)
    
    res_levels = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid + ".18"
    ], mutates=False)
    
    raw_value = None
    multiplier = 1.0
    offset = 0.0
    
    for line in res_value.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if value_part.startswith("INTEGER:"):
            loc = oid_part.rsplit(".", 1)[-1]
            if loc == location:
                value_str = value_part.split(":")[1].strip()
                if value_str.isdigit():
                    raw_value = int(value_str)
                break
    
    for line in res_levels.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if value_part.startswith("STRING:") or value_part.startswith("OCTETSTRING:"):
            equation_str = value_part.split(":", 1)[1].strip().strip('"')
            if equation_str == "":
                continue
            
            equation_parts = []
            current_part = []
            for i in range(len(equation_str)):
                char = equation_str[i]
                if char == '\x00':
                    if current_part:
                        equation_parts.append("".join(current_part))
                        current_part = []
                else:
                    current_part.append(char)
            if current_part:
                equation_parts.append("".join(current_part))
            
            if len(equation_parts) >= 1:
                unit_indicator = equation_parts[0]
                if "mV" in unit_indicator or ("#" in unit_indicator and "m" in unit_indicator):
                    loc = oid_part.rsplit(".", 1)[-1]
                    if loc == location:
                        eq_str = equation_parts[1]
                        eq_str = eq_str.replace("-", "+-").split("+")
                        if len(eq_str) == 2:
                            mult_str = eq_str[0]
                            off_str = eq_str[1]
                            if mult_str.replace('.', '', 1).replace('-', '', 1).isdigit() and off_str.replace('.', '', 1).replace('-', '', 1).isdigit():
                                multiplier = float(mult_str)
                                offset = float(off_str)
                        elif len(eq_str) == 1:
                            mult_str = eq_str[0]
                            if mult_str.replace('.', '', 1).replace('-', '', 1).isdigit():
                                multiplier = float(mult_str)
                        break
    
    if raw_value == None:
        return {
            "changed": False,
            "msg": "sensor not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    voltage = (raw_value * multiplier) + offset
    
    warn = 200.0
    crit = 180.0
    levels_lower = params.get("levels_lower", (None, None))
    if levels_lower[0] != None:
        warn = levels_lower[0]
    if levels_lower[1] != None:
        crit = levels_lower[1]
    
    if voltage <= crit:
        state = "CRIT"
    elif voltage <= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Phase %s: %f V" % (location, voltage)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"voltage": voltage},
            "details": ""
        }
    }