def main(ctx, params):
    if params.get("_discover"):
        # Discover inputs by walking the SNMP tree for poseidon_inputs
        base_oid = ".1.3.6.1.4.1.21796.3.3.1.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 inputs",
                    "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        entries = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            if "=" not in line:
                continue
            oid_part, value_part = line.split("=", 1)
            oid_str = oid_part.strip()
            value_str = value_part.strip()
            
            if not oid_str.startswith(base_oid + "."):
                continue
            suffix = oid_str[len(base_oid) + 1:]
            parts = suffix.split(".")
            if len(parts) != 2:
                continue
            input_type_str = parts[0]
            idx_str = parts[1]
            # Guard: validate numeric strings before conversion
            if not input_type_str.isdigit() or not idx_str.isdigit():
                continue
            input_type = int(input_type_str)
            idx = int(idx_str)
            
            field_map = {2: "input_value", 3: "input_name", 4: "input_alarm_setup", 5: "input_alarm_state"}
            field_name = field_map.get(input_type)
            if field_name == None:
                continue
            
            # Strip type prefix from value
            if value_str.startswith("INTEGER: "):
                value_str = value_str[len("INTEGER: "):]
            elif value_str.startswith("STRING: "):
                value_str = value_str[len("STRING: "):]
                value_str = value_str.strip('"')
            
            if idx not in entries:
                entries[idx] = {"input_name": ""}
            
            if field_name == "input_name":
                entries[idx]["input_name"] = value_str
            elif field_name in ["input_value", "input_alarm_setup", "input_alarm_state"]:
                if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
                    entries[idx][field_name] = int(value_str)
                else:
                    entries[idx][field_name] = 3
        
        out = []
        for idx, data in entries.items():
            item = data.get("input_name")
            if item == "":
                item = "Eingang " + str(idx)
            out.append({"item": item, "params": {},
                        "metrics": []})
        return {"changed": False, "msg": "discovered %d inputs" % len(out),
                "data": {"discovery": out}}
    
    # Check mode
    item = params.get("item", "")
    base_oid = ".1.3.6.1.4.1.21796.3.3.1.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), base_oid
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP failure",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    entries = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        oid_str = oid_part.strip()
        value_str = value_part.strip()
        if not oid_str.startswith(base_oid + "."):
            continue
        suffix = oid_str[len(base_oid) + 1:]
        parts = suffix.split(".")
        if len(parts) != 2:
            continue
        input_type_str = parts[0]
        idx_str = parts[1]
        if not input_type_str.isdigit() or not idx_str.isdigit():
            continue
        input_type = int(input_type_str)
        idx = int(idx_str)
        field_map = {2: "input_value", 3: "input_name", 4: "input_alarm_setup", 5: "input_alarm_state"}
        field_name = field_map.get(input_type)
        if field_name == None:
            continue
        if value_str.startswith("INTEGER: "):
            value_str = value_str[len("INTEGER: "):]
        elif value_str.startswith("STRING: "):
            value_str = value_str[len("STRING: "):]
            value_str = value_str.strip('"')
        if idx not in entries:
            entries[idx] = {"input_name": ""}
        if field_name == "input_name":
            entries[idx]["input_name"] = value_str
        elif field_name in ["input_value", "input_alarm_setup", "input_alarm_state"]:
            if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
                entries[idx][field_name] = int(value_str)
            else:
                entries[idx][field_name] = 3
    
    data = None
    for idx, entry in entries.items():
        candidate = entry.get("input_name")
        if candidate == "":
            candidate = "Eingang " + str(idx)
        if candidate == item:
            data = entry
            break
    
    if data == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    alarm_setup_map = {0: "inactive", 1: "activeOff", 2: "activeOn", 3: "unkown"}
    input_value_map = {0: "off", 1: "on", 3: "unkown"}
    alarm_state_map = {0: "normal", 1: "alarm", 3: "unkown"}
    
    alarm_setup_value = data.get("input_alarm_setup", 3)
    alarm_state_value = data.get("input_alarm_state", 3)
    input_value = data.get("input_value", 3)
    
    state = "CRIT" if alarm_state_value == 1 else "OK"
    
    msg = "%s: AlarmSetup: %s, Alarm State: %s, Values: %s" % (
        item, alarm_setup_map.get(alarm_setup_value, "unknown"),
        alarm_state_map.get(alarm_state_value, "unknown"),
        input_value_map.get(input_value, "unknown")
    )
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}