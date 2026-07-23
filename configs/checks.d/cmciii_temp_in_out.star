# ===== module-level constants =====
OID_BASE_TEMP_IN_OUT = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
OID_BASE_VALUE = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.2"
ITEM_KEY_PARAM = "_item_key"


def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, OID_BASE_TEMP_IN_OUT], mutates=False)
        
        sensors = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            oid_segments = oid_full.split(".")
            if len(oid_segments) < 2:
                continue
            sensor_id = oid_segments[-1]
            if not sensor_id.isdigit():
                continue
            sensor_id = int(sensor_id)
            
            value_str = value_part.strip()
            if value_str.startswith("STRING: "):
                desc = value_str[8:].strip("'").strip()
            else:
                desc = value_str.strip('"')
            
            use_desc = params.get("use_sensor_description", False)
            if use_desc:
                desc_parts = desc.split(".")
                if len(desc_parts) >= 3 and desc_parts[2].isdigit():
                    location = desc_parts[1]
                    index = desc_parts[2]
                    item_name = "{}-{} {}".format(location, index, desc)
                else:
                    item_name = desc
            else:
                item_name = str(sensor_id)
            
            sensors.append({
                "item": item_name,
                "params": {"_item_key": str(sensor_id)},
                "metrics": ["temp"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(sensors),
            "data": {"discovery": sensors}
        }
    
    # ===== CHECK MODE =====
    item = params.get("item", "")
    sensor_id = str(params.get(ITEM_KEY_PARAM, item))
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, OID_BASE_VALUE], mutates=False)
    
    temp_value = None
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value_part = parts
        oid_segments = oid_full.split(".")
        if len(oid_segments) < 2:
            continue
        oid_sensor_id = oid_segments[-1]
        if oid_sensor_id != sensor_id:
            continue
        value_str = value_part.strip()
        if value_str.startswith("INTEGER: "):
            val_str = value_str[9:].strip()
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                temp_value = float(val_str)
                break
    
    if temp_value == None:
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, OID_BASE_TEMP_IN_OUT + "." + sensor_id], mutates=False)
        if res.rc == 0 and res.stdout.strip():
            parts = res.stdout.strip().split(" = ")
            if len(parts) == 2:
                value_part = parts[1].strip()
                prefixes = ["INTEGER: ", "GAUGE: ", "COUNTER: "]
                for prefix in prefixes:
                    if value_part.startswith(prefix):
                        val_str = value_part[len(prefix):].strip()
                        if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                            temp_value = float(val_str)
                            break
                if temp_value == None and value_part.isdigit():
                    temp_value = float(value_part)
    
    if temp_value == None:
        return {
            "changed": False,
            "msg": "temperature sensor %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    levels = params.get("levels", (25.0, 30.0))
    if type(levels) == "list":
        warn_upper_val = levels[1] if len(levels) > 1 else levels[0]
        crit_upper_val = levels[1] if len(levels) > 1 else levels[0]
        warn_lower_val = None
        crit_lower_val = None
    else:
        warn_upper_val = 25.0
        crit_upper_val = 30.0
        warn_lower_val = None
        crit_lower_val = None
    
    state = "OK"
    if warn_upper_val != None and temp_value >= warn_upper_val:
        state = "WARN"
    if crit_upper_val != None and temp_value >= crit_upper_val:
        state = "CRIT"
    if warn_lower_val != None and temp_value <= warn_lower_val:
        state = "WARN"
    if crit_lower_val != None and temp_value <= crit_lower_val:
        state = "CRIT"
    
    msg = "Temperature %f C" % temp_value
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": temp_value},
            "details": ""
        }
    }
