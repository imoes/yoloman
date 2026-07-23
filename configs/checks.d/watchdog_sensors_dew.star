def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        res_general = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.21239.5.1.1.7"
        ], mutates=False)
        
        temp_unit = "C"
        if res_general.rc == 0:
            for line in res_general.stdout.splitlines():
                if ".1.3.6.1.4.1.21239.5.1.1.7.0" in line:
                    val = line.split(" = ")
                    if len(val) > 1:
                        raw_unit = val[1].strip()
                        if raw_unit.isdigit():
                            temp_unit = "C" if raw_unit == "1" else "F"
                    break
        
        res_version = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.21239.5.1.1.2"
        ], mutates=False)
        
        version = 320
        if res_version.rc == 0:
            for line in res_version.stdout.splitlines():
                if ".1.3.6.1.4.1.21239.5.1.1.2.0" in line:
                    val = line.split(" = ")
                    if len(val) > 1:
                        ver_str = val[1].strip().split(".")
                        if len(ver_str) == 3:
                            ver_concat = ver_str[0] + ver_str[1] + ver_str[2]
                            if ver_concat.isdigit():
                                ver_int = int(ver_concat)
                                if ver_int <= 300:
                                    version = 300
                                else:
                                    version = 320
                        break
        
        res_sensors = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.21239.5.1.2.1"
        ], mutates=False)
        
        discovery_items = []
        current_sensor = None
        sensor_data = {}
        
        for line in res_sensors.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            
            oid = parts[0].strip()
            value = parts[1].strip()
            
            if oid.endswith(".1"):
                if current_sensor != None and "dew" in sensor_data:
                    item_name = "Dew point " + current_sensor
                    discovery_items.append({
                        "item": item_name,
                        "params": {},
                        "metrics": ["dew_point"]
                    })
                current_sensor = value.strip('"')
                sensor_data = {}
            elif current_sensor != None:
                if oid.endswith(".3"):
                    sensor_data["desc"] = value.strip('"')
                elif oid.endswith(".5"):
                    sensor_data["temp"] = value
                elif oid.endswith(".6"):
                    sensor_data["humidity"] = value
                elif oid.endswith(".7"):
                    sensor_data["dew"] = value
        
        if current_sensor != None and "dew" in sensor_data:
            item_name = "Dew point " + current_sensor
            discovery_items.append({
                "item": item_name,
                "params": {},
                "metrics": ["dew_point"]
            })
        
        return {"changed": False, "msg": "discovered %d dew points" % len(discovery_items),
                "data": {"discovery": discovery_items}}
    
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    sensor_id = item.split()[-1]
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.21239.5.1.2.1.7." + sensor_id
    ], mutates=False)
    
    if res.rc != 0 or "No such variable" in res.stderr:
        return {"changed": False, "msg": "dew point sensor not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    output = res.stdout.strip()
    if not output:
        return {"changed": False, "msg": "empty response from SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts = output.split(" = ")
    if len(parts) < 2:
        return {"changed": False, "msg": "unexpected SNMP output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_part = parts[1].strip()
    if value_part.startswith("INTEGER:"):
        dew_raw = value_part.split(":")[1].strip()
    else:
        dew_raw = value_part
    
    if not dew_raw.isdigit():
        return {"changed": False, "msg": "invalid dew point value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    dew = float(dew_raw) / 10.0
    
    res_general = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.21239.5.1.1.7"
    ], mutates=False)
    
    temp_unit = "C"
    if res_general.rc == 0:
        for line in res_general.stdout.splitlines():
            if ".1.3.6.1.4.1.21239.5.1.1.7.0" in line:
                val = line.split(" = ")
                if len(val) > 1:
                    raw_unit = val[1].strip()
                    if raw_unit.isdigit():
                        temp_unit = "C" if raw_unit == "1" else "F"
                    break
    
    if temp_unit == "F":
        dew = 5.0 / 9.0 * (dew - 32.0)
    
    warn_upper = params.get("levels", (None, None))
    if type(warn_upper) == tuple and len(warn_upper) >= 2:
        warn_val, crit_val = warn_upper[0], warn_upper[1]
    else:
        warn_val, crit_val = None, None
    
    state = "OK"
    msg = ""
    
    if warn_val != None and crit_val != None:
        if dew >= crit_val:
            state = "CRIT"
            msg = "%f C (warn/crit at %f/%f C)" % (dew, warn_val, crit_val)
        elif dew >= warn_val:
            state = "WARN"
            msg = "%f C (warn/crit at %f/%f C)" % (dew, warn_val, crit_val)
        else:
            msg = "%f C" % dew
    else:
        msg = "%f C" % dew
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"dew_point": dew},
            "details": "",
        },
    }