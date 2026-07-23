def main(ctx, params):
    # Read the siemens_plc section from the agent
    res = ctx.run(["cat", "/var/lib/yolo-man/agent/Cache/cmk_siemens_plc"], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "siemens_plc section not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = []
    for line in res.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3:
            section.append(fields)
    
    if params.get("_discover"):
        items = []
        for line in section:
            if len(line) >= 2 and line[1].startswith("counter"):
                item = line[0] + " " + line[2]
                items.append({"item": item, "params": {}, "metrics": ["counter"]})
        return {"changed": False, "msg": "discovered %d counters" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item is required", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value = None
    metric_name = None
    for line in section:
        if len(line) >= 3 and line[1].startswith("counter") and (line[0] + " " + line[2]) == item:
            raw_val = line[-1]
            if raw_val.isdigit() or (raw_val.startswith("-") and raw_val[1:].isdigit()):
                value = int(raw_val)
                metric_name = line[1]
                break
    
    if value == None:
        return {"changed": False, "msg": "counter not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    levels = params.get("levels")
    
    # Check for counter wrap (reduced value)
    key = "siemens_plc.counter." + item
    old_value = ctx._value_store.get(key)
    ctx._value_store[key] = value
    
    if old_value != None and int(old_value) > value:
        return {"changed": False, "msg": "Reduced from %d to %d" % (int(old_value), value),
                "data": {"state": "CRIT", "metrics": {metric_name: float(value)}, "details": ""}}
    
    state = "OK"
    if levels != None:
        if len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]
            if value >= crit:
                state = "CRIT"
            elif value >= warn:
                state = "WARN"
        elif len(levels) == 1:
            crit = levels[0]
            if value >= crit:
                state = "CRIT"
    
    return {"changed": False, "msg": "Counter: %d" % value,
            "data": {"state": state, "metrics": {metric_name: float(value)}, "details": ""}}