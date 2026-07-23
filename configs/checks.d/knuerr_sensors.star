def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.3711.15.1.1.2"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid, ".1.3.6.1.4.1.3711.15.1.1.2.1",
            ".1.3.6.1.4.1.3711.15.1.1.2.5"
        ], mutates=False)
        
        sensor_map = {}
        lines = res.stdout.splitlines()
        
        for line in lines:
            if not line.strip():
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value_part = parts[1].strip()
            
            if oid.endswith(".1"):
                idx = oid.rsplit(".", 1)[1]
                if idx.isdigit():
                    sensor_name = value_part.strip('"')
                    sensor_map[idx] = [sensor_name, None]
            elif oid.endswith(".5"):
                idx = oid.rsplit(".", 1)[1]
                if idx.isdigit():
                    state_str = value_part
                    if state_str.startswith("INTEGER: "):
                        state_str = state_str[len("INTEGER: "):]
                    if state_str.lstrip('-').isdigit():
                        state = int(state_str)
                        if idx in sensor_map:
                            sensor_map[idx][1] = state
                        else:
                            sensor_map[idx] = [None, state]
        
        discovery_items = []
        for idx, (sensor_name, state) in sorted(sensor_map.items()):
            if sensor_name and sensor_name != "":
                discovery_items.append({
                    "item": sensor_name,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.3711.15.1.1.2"
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid, ".1.3.6.1.4.1.3711.15.1.1.2.1",
        ".1.3.6.1.4.1.3711.15.1.1.2.5"
    ], mutates=False)
    
    lines = res.stdout.splitlines()
    found = False
    
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value_part = parts[1].strip()
        
        if oid.startswith(base_oid + ".1."):
            idx = oid.rsplit(".", 1)[1]
            if idx.isdigit():
                sensor_value = value_part.strip('"')
                if sensor_value == item:
                    found = True
                    state_oid = oid.rsplit(".", 1)[0] + ".5"
                    for state_line in lines:
                        if state_line.startswith(state_oid + " = "):
                            state_str = state_line.split(" = ", 1)[1].strip()
                            if state_str.startswith("INTEGER: "):
                                state_str = state_str[len("INTEGER: "):]
                            if state_str.lstrip('-').isdigit():
                                state = int(state_str)
                                if state != 0:
                                    return {
                                        "changed": False,
                                        "msg": "Sensor triggered",
                                        "data": {
                                            "state": "CRIT",
                                            "metrics": {},
                                            "details": ""
                                        }
                                    }
                                else:
                                    return {
                                        "changed": False,
                                        "msg": "Sensor not triggered",
                                        "data": {
                                            "state": "OK",
                                            "metrics": {},
                                            "details": ""
                                        }
                                    }
    
    return {
        "changed": False,
        "msg": "Sensor no longer found",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }