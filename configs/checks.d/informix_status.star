def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["onstat", "-c", "online"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "onstat not installed", "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no informix", "data": {"discovery": []}}
        out = []
        instances = {}
        for line in res.stdout.splitlines():
            s = line.strip()
            if s.startswith("[[[") and s.endswith("]]]"):
                instances[s[3:-3]] = 1
        for inst in instances:
            out.append({"item": inst, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["onstat", "-c", "online"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "onstat not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no informix instance: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = {}
    instance = None
    for line in res.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0].startswith("[[[") and parts[0].endswith("]]]"):
            instance = parts[0][3:-3]
        elif instance != None and len(parts) >= 2:
            parsed.setdefault(instance, {})
            vals = []
            for p in parts[1:]:
                vals.append(p.strip())
            parsed[instance].setdefault(parts[0], " ".join(vals))
    if item not in parsed:
        return {"changed": False, "msg": "no informix instance: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = parsed[item]
    map_states = {
        "0": ("OK", "initialization"),
        "1": ("WARN", "quiescent"),
        "2": ("WARN", "recovery"),
        "3": ("WARN", "backup"),
        "4": ("CRIT", "shutdown"),
        "5": ("OK", "online"),
        "6": ("WARN", "abort"),
        "7": ("WARN", "single user"),
        "-1": ("CRIT", "offline"),
        "255": ("CRIT", "offline"),
    }
    st = data.get("Status", "")
    state_readable = "unknown"
    state = "UNKNOWN"
    if st in map_states:
        state, state_readable = map_states[st]
    infotext = "Status: %s" % state_readable
    sv = data.get("Server Version")
    if sv:
        infotext = infotext + ", Version: %s" % sv
    port = data.get("PORT")
    if port:
        p = port.split(" ")
        if len(p) >= 2:
            infotext = infotext + ", Port: %s" % p[1]
    return {"changed": False, "msg": "%s %s" % (item, infotext), "data": {"state": state, "metrics": {}, "details": ""}}