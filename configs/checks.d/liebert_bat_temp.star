def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.476.1.42.3.4.1.3.3.1.3"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            value_str = parts[1].strip()
            if value_str.startswith("INTEGER: "):
                suffix = value_str[9:].strip()
                is_valid = False
                if suffix.isdigit():
                    is_valid = True
                elif suffix.startswith("-") and len(suffix) > 1 and suffix[1:].isdigit():
                    is_valid = True
                if is_valid:
                    val = int(suffix)
                    items.append({"item": "Battery", "params": {"levels": (40.0, 50.0)},
                                  "metrics": ["temp"]})
                    break
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    if item != "Battery":
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.476.1.42.3.4.1.3.3.1.3.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP get failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    output = res.stdout.strip()
    if not output:
        return {"changed": False, "msg": "empty SNMP response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp = 0
    if " = INTEGER: " in output:
        suffix = output.split(" = INTEGER: ")[1].strip()
        is_valid = False
        if suffix.isdigit():
            is_valid = True
        elif suffix.startswith("-") and len(suffix) > 1 and suffix[1:].isdigit():
            is_valid = True
        if is_valid:
            temp = int(suffix)
        else:
            return {"changed": False, "msg": "invalid temperature value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "could not parse temperature value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    warn, crit = params.get("levels", (40.0, 50.0))
    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    
    msg = "Temperature Battery: %f C" % temp
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temp": float(temp)}, "details": ""}}