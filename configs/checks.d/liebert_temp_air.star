# ===== Starlark check: liebert_temp_air =====

def _parse_snmp_table(lines):
    parsed = {}
    used_names = []
    counter = 2
    
    label = ""
    value = ""
    unit = ""
    parsing_label = True
    parsing_value = False
    parsing_unit = False
    
    for line in lines:
        if " = " not in line:
            continue
        oid_part, value_part = line.split(" = ", 1)
        value_part = value_part.strip()
        if value_part.startswith("STRING: "):
            val = value_part[8:].strip().strip('"')
        elif value_part.startswith("INTEGER: "):
            val = value_part[9:]
        elif value_part.startswith(" Gauge32: "):
            val = value_part[10:]
        elif value_part.startswith(" Counter32: "):
            val = value_part[12:]
        elif value_part.startswith(" Timeticks: "):
            val = value_part[12:]
        else:
            val = value_part
        
        if ".4291." in oid_part or ".5002." in oid_part:
            idx4291 = oid_part.rfind(".4291")
            idx5002 = oid_part.rfind(".5002")
            if idx4291 > 0:
                suffix = oid_part[idx4291 + len(".4291"):].strip(".")
            elif idx5002 > 0:
                suffix = oid_part[idx5002 + len(".5002"):].strip(".")
            else:
                continue
            
            parts = suffix.split(".")
            if len(parts) >= 1:
                field_num = parts[0]
                if field_num == "10":
                    parsing_label = True
                    parsing_value = False
                    parsing_unit = False
                elif field_num == "20":
                    parsing_label = False
                    parsing_value = True
                    parsing_unit = False
                elif field_num == "30":
                    parsing_label = False
                    parsing_value = False
                    parsing_unit = True
                else:
                    continue
            else:
                continue
        
        if parsing_label:
            label = val
            parsing_label = False
        elif parsing_value:
            value = val
            parsing_value = False
        elif parsing_unit:
            unit = val
            parsing_unit = False
            
            if label:
                new_label = label
                if label in used_names:
                    new_label = "%s %d" % (label, counter)
                    counter += 1
                used_names.append(label)
                parsed[new_label] = (value, unit)
            
            label = ""
            value = ""
            unit = ""
    
    return parsed

def _get_item_from_key(key):
    return key.replace(" Air Temperature", "").strip()

def _temperature_to_celsius(reading, unit):
    unit_clean = unit.replace("deg ", "").lower().strip()
    # Guard instead of try/except
    # Check if reading is a valid number string
    temp_str = str(reading).strip()
    # Simple validation: must contain digits and optionally dot/minus
    valid = True
    found_digit = False
    for c in temp_str:
        if c >= '0' and c <= '9':
            found_digit = True
        elif c != '.' and c != '-' and c != '+':
            valid = False
    if not found_digit:
        valid = False
    
    if not valid:
        return None
    
    val = float(temp_str)
    
    if unit_clean == "c" or unit_clean == "%":
        return val
    elif unit_clean == "f":
        return (val - 32) * (5.0 / 9.0)
    elif unit_clean == "k":
        return val - 273.15
    else:
        return None

def _get_system_state(section_system, key):
    if section_system == None:
        return ""
    return section_system.get(key, "")

def _check_temperature(temperature, params, item):
    warn = params.get("levels", (None, None))
    crit = params.get("levels_lower", (None, None))
    
    upper_warn = None
    upper_crit = None
    lower_warn = None
    lower_crit = None
    
    if type(warn) == "list":
        if len(warn) >= 2:
            upper_warn = warn[0]
            upper_crit = warn[1]
        elif len(warn) == 1:
            upper_warn = warn[0]
    elif type(warn) == "string":
        upper_warn = warn
    elif type(warn) == "float" or type(warn) == "int":
        upper_warn = warn
    
    if type(crit) == "list":
        if len(crit) >= 2:
            lower_warn = crit[0]
            lower_crit = crit[1]
        elif len(crit) == 1:
            lower_warn = crit[0]
    elif type(crit) == "string":
        lower_crit = crit
    elif type(crit) == "float" or type(crit) == "int":
        lower_crit = crit
    
    state = "OK"
    summary_parts = []
    
    if upper_warn != None and temperature >= upper_warn:
        state = "WARN"
    if upper_crit != None and temperature >= upper_crit:
        state = "CRIT"
    
    if lower_warn != None and temperature <= lower_warn:
        state = "WARN"
    if lower_crit != None and temperature <= lower_crit:
        state = "CRIT"
    
    summary_parts.append("%f" % temperature + " C")
    if upper_warn != None or upper_crit != None:
        if upper_warn != None:
            summary_parts.append("warn@%f" % upper_warn)
        if upper_crit != None:
            summary_parts.append("crit@%f" % upper_crit)
    if lower_warn != None or lower_crit != None:
        if lower_warn != None:
            summary_parts.append("lower_warn@%f" % lower_warn)
        if lower_crit != None:
            summary_parts.append("lower_crit@%f" % lower_crit)
    
    details = " ".join(summary_parts)
    return {
        "state": state,
        "details": details,
        "metrics": {"temp": temperature},
    }

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP error: " + res.stderr,
                "data": {"discovery": []}
            }
        
        lines = res.stdout.splitlines()
        section_liebert_temp_air = _parse_snmp_table(lines)
        
        res_sys = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.476.1.42.3.9.10.1"
        ], mutates=False)
        
        section_liebert_system = {}
        if res_sys.rc == 0:
            sys_lines = res_sys.stdout.splitlines()
            for line in sys_lines:
                if " = " not in line:
                    continue
                oid_part, value_part = line.split(" = ", 1)
                value_part = value_part.strip()
                if value_part.startswith("STRING: "):
                    val = value_part[8:].strip().strip('"')
                else:
                    val = value_part
                base = ".1.3.6.1.4.1.476.1.42.3.9.10.1."
                if oid_part.startswith(base):
                    suffix = oid_part[len(base):]
                    parts = suffix.split(".")
                    if len(parts) >= 2:
                        label = parts[-2] + " " + parts[-1]
                        label = label.replace("_", " ")
                        section_liebert_system[label] = val
        
        out = []
        for key in section_liebert_temp_air:
            item = _get_item_from_key(key)
            value, unit = section_liebert_temp_air[key]
            if "Unavailable" not in value:
                out.append({
                    "item": item,
                    "params": {},
                    "metrics": ["temp"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}
        }
    
    item = params.get("item", "")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    section_liebert_temp_air = _parse_snmp_table(lines)
    
    res_sys = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.476.1.42.3.9.10.1"
    ], mutates=False)
    
    section_liebert_system = {}
    if res_sys.rc == 0:
        sys_lines = res_sys.stdout.splitlines()
        for line in sys_lines:
            if " = " not in line:
                continue
            oid_part, value_part = line.split(" = ", 1)
            value_part = value_part.strip()
            if value_part.startswith("STRING: "):
                val = value_part[8:].strip().strip('"')
            else:
                val = value_part
            base = ".1.3.6.1.4.1.476.1.42.3.9.10.1."
            if oid_part.startswith(base):
                suffix = oid_part[len(base):]
                parts = suffix.split(".")
                if len(parts) >= 2:
                    label = parts[-2] + " " + parts[-1]
                    label = label.replace("_", " ")
                    section_liebert_system[label] = val
    
    item_data = None
    for key in section_liebert_temp_air:
        if _get_item_from_key(key) == item:
            item_data = section_liebert_temp_air[key]
            break
    
    if item_data == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value, unit = item_data
    
    unit_state = section_liebert_system.get("Unit Operating State", "")
    if "Unavailable" in value and unit_state == "standby":
        return {
            "changed": False,
            "msg": "Unit is in standby (unavailable)",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }
    
    celsius = _temperature_to_celsius(value, unit)
    if celsius == None:
        return {
            "changed": False,
            "msg": "unable to parse temperature value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    result = _check_temperature(celsius, params, item)
    
    return {
        "changed": False,
        "msg": result["details"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": "",
        }
    }