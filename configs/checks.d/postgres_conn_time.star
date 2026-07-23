def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/postgres_conn_time"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        parsed = {}
        instance_name = ""
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("[[[") and stripped.endswith("]]]"):
                instance_name = stripped[3:-3].upper()
            elif stripped:
                # Guard against float conversion failure
                value = float(stripped) if stripped.replace(".", "", 1).isdigit() or (stripped.startswith("-") and stripped[1:].replace(".", "", 1).isdigit()) else None
                if value != None:
                    parsed.setdefault(instance_name, value)
        
        items = []
        for name in parsed:
            items.append({"item": name, "params": {}, "metrics": ["connection_time"]})
        
        return {"changed": False, "msg": "discovered %d instances" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/postgres_conn_time"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read agent data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parsed = {}
    instance_name = ""
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("[[[") and stripped.endswith("]]]"):
            instance_name = stripped[3:-3].upper()
        elif stripped:
            # Guard against float conversion failure
            value = float(stripped) if stripped.replace(".", "", 1).isdigit() or (stripped.startswith("-") and stripped[1:].replace(".", "", 1).isdigit()) else None
            if value != None:
                parsed.setdefault(instance_name, value)
    
    if item not in parsed:
        return {"changed": False, "msg": "Login into database failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    conn_time = parsed[item]
    return {"changed": False, "msg": "%f seconds" % conn_time,
            "data": {"state": "OK", "metrics": {"connection_time": conn_time}, "details": ""}}