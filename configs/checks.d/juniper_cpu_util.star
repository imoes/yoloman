def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        detect = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Ovqn",
            host, ".1.3.6.1.2.1.1.2.0",
        ], mutates=False)
        if detect.rc != 0 or not detect.stdout:
            return {"changed": False, "msg": "host is not a Juniper device",
                    "data": {"discovery": []}}
        sys_oid = detect.stdout.split()
        is_juniper = False
        for token in sys_oid:
            if token.startswith(".1.3.6.1.4.1.2636.1.1.1"):
                is_juniper = True
                break
        if not is_juniper:
            return {"changed": False, "msg": "host is not a Juniper device",
                    "data": {"discovery": []}}
        walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Ovqn",
            host, ".1.3.6.1.4.1.2636.3.1.13.1",
        ], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed",
                    "data": {"discovery": []}}
        devices = {}
        for line in walk.stdout.splitlines():
            idx_space = line.find(" ")
            if idx_space < 0:
                continue
            oid = line[:idx_space]
            value = line[idx_space + 1:]
            suffix = oid[len(".1.3.6.1.4.1.2636.3.1.13.1"):]
            parts = suffix.split(".", 1)
            if len(parts) != 2 or not parts[1]:
                continue
            col = parts[0]
            inst = parts[1]
            if col == "5":
                devices[inst] = {"name": value, "util": None}
            elif col == "8":
                if inst in devices:
                    devices[inst]["util"] = value
        discovery = []
        for inst in devices:
            info = devices[inst]
            if info["util"] == None:
                continue
            util = int(info["util"]) if info["util"].lstrip("-").isdigit() else -1
            if util < 0:
                continue
            if util:
                name = info["name"].replace("@ ", "").replace("/*", "").strip()
                levels = params.get("levels", (80.0, 90.0))
                discovery.append({
                    "item": name,
                    "params": {"levels": [levels[0], levels[1]]},
                    "metrics": ["cpu_util"],
                })
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    walk = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Ovqn",
        host, ".1.3.6.1.4.1.2636.3.1.13.1",
    ], mutates=False)
    if walk.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    devices = {}
    for line in walk.stdout.splitlines():
        idx_space = line.find(" ")
        if idx_space < 0:
            continue
        oid = line[:idx_space]
        value = line[idx_space + 1:]
        suffix = oid[len(".1.3.6.1.4.1.2636.3.1.13.1"):]
        parts = suffix.split(".", 1)
        if len(parts) != 2 or not parts[1]:
            continue
        col = parts[0]
        inst = parts[1]
        if col == "5":
            devices[inst] = {"name": value, "util": None}
        elif col == "8":
            if inst in devices:
                devices[inst]["util"] = value
    found = None
    for inst in devices:
        info = devices[inst]
        name = info["name"].replace("@ ", "").replace("/*", "").strip()
        if name == item:
            found = info
            break
    if found == None or found["util"] == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    util = int(found["util"]) if found["util"].lstrip("-").isdigit() else 0
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if len(levels) > 0 else 80.0
    crit = levels[1] if len(levels) > 1 else 90.0
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "CPU utilization %d%%" % util,
            "data": {"state": state, "metrics": {"cpu_util": util}, "details": ""}}