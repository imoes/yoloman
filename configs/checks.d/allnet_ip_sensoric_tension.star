def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", "80")
    path = params.get("path", "/json")
    
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "http://%s:%s%s" % (host, port, path)], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "discovered 0 sensors (no data)",
                "data": {"discovery": []}
            }
        data = json.decode(res.stdout)
        items = []
        if type(data) == "dict" and "sensors" in data:
            sensors = data["sensors"]
            if type(sensors) == "list":
                for s in sensors:
                    if type(s) == "dict":
                        func = s.get("function", "")
                        unit = s.get("unit", "")
                        if func == "12" or (func == "" and unit == "%"):
                            name = s.get("name", "")
                            sid = s.get("id", "")
                            item = "%s Sensor %s" % (name, sid) if name else "Sensor %s" % sid
                            items.append({
                                "item": item,
                                "params": {},
                                "metrics": ["tension"]
                            })
        return {
            "changed": False,
            "msg": "discovered %d tension sensors" % len(items),
            "data": {"discovery": items}
        }
    
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    parts = item.split(" Sensor ")
    if len(parts) == 2:
        sensor_id = parts[1]
    elif item.startswith("Sensor "):
        sensor_id = item[7:]
    else:
        return {
            "changed": False,
            "msg": "invalid item format: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    res = ctx.run(["curl", "-s", "http://%s:%s%s" % (host, port, path)], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "no data from device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    data = json.decode(res.stdout)
    
    tension_value = None
    if type(data) == "dict" and "sensors" in data:
        sensors = data["sensors"]
        if type(sensors) == "list":
            for s in sensors:
                if type(s) == "dict" and s.get("id", "") == sensor_id:
                    tension_value = s.get("value_float", "")
                    break
    
    if tension_value == None:
        return {
            "changed": False,
            "msg": "sensor %s not found" % sensor_id,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value = float(tension_value) if tension_value != "" else -1.0
    
    state = "OK" if value == 0 else "CRIT"
    
    msg = "%d%% of the normal level" % int(value + 0.5)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"tension": value},
            "details": ""
        }
    }