def main(ctx, params):
    if params.get("_discover"):
        # Probe for the data source: wmic (Windows Management Instrumention CLI)
        res = ctx.run(["wmic", "path", "Win32_PerfRawData_W3SVC_W3SVC", "get", "Name,CurrentConnections", "/value"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no web services data available (wmic/wmi not present)",
                    "data": {"discovery": []}}
        raw = res.stdout
        instances = []
        for line in raw.splitlines():
            line = line.strip()
            if line == "" or line == "None":
                continue
            if line.startswith("Name="):
                name = line[len("Name="):]
                instances.append(name)
        discovery = []
        for name in instances:
            discovery.append({"item": name, "params": {}, "metrics": ["connections"]})
        return {"changed": False, "msg": "discovered %d web services" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["wmic", "path", "Win32_PerfRawData_W3SVC_W3SVC", "get", "Name,CurrentConnections", "/value"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no web service data available (wmi not present)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout
    found_value = None
    current_name = ""
    for line in raw.splitlines():
        line = line.strip()
        if line == "" or line == "None":
            continue
        if line.startswith("Name="):
            current_name = line[len("Name="):]
            found_value = None
        elif line.startswith("CurrentConnections="):
            found_value = line[len("CurrentConnections="):]
            if current_name == item:
                break
    if current_name != item or found_value == None:
        return {"changed": False, "msg": "web service %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    connections = int(found_value) if found_value.isdigit() else 0
    return {"changed": False, "msg": "Web Service %s: Connections: %d" % (item, connections),
            "data": {"state": "OK", "metrics": {"connections": connections}, "details": ""}}