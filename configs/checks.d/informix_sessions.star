def main(ctx, params):
    if params.get("_discover"):
        onstat = ctx.run(["sh", "-c", "command -v onstat"], mutates=False)
        if onstat.rc != 0 or not onstat.stdout.strip():
            return {"changed": False, "msg": "no Informix installation found", "data": {"discovery": []}}
        inst_dir = None
        for line in onstat.stdout.splitlines():
            s = line.strip()
            if s:
                inst_dir = s
                break
        if inst_dir == None:
            for cand in ["/opt/informix", "/usr/informix", "/usr/local/informix"]:
                st = ctx.stat(cand)
                if st != None and st.get("is_dir"):
                    inst_dir = cand
                    break
        if inst_dir == None:
            return {"changed": False, "msg": "no Informix installation found", "data": {"discovery": []}}
        rep = ctx.run(["sh", "-c", "onstat -g ses 2>/dev/null | head -n 200"], mutates=False)
        if rep.rc != 0 or not rep.stdout:
            return {"changed": False, "msg": "Informix not reachable", "data": {"discovery": []}}
        lines = rep.stdout.splitlines()
        idx = 0
        instance = None
        sessions = None
        while idx < len(lines):
            ln = lines[idx]
            parts = ln.split()
            if ln.find("[[[") == 0 and ln.find("]]]") > 0:
                end = ln.find("]]]")
                instance = ln[3:end]
            elif instance != None and len(parts) >= 2 and parts[0] == "SESSIONS":
                if parts[1].isdigit():
                    sessions = int(parts[1])
                    break
            idx = idx + 1
        if instance == None or sessions == None:
            return {"changed": False, "msg": "no session data parsed", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 instance", "data": {"discovery": [{"item": instance, "params": {"levels": (50, 60)}, "metrics": ["sessions"]}]}}
    item = params.get("item", "")
    levels = params.get("levels", (50, 60))
    warn = levels[0]
    crit = levels[1]
    onstat = ctx.run(["sh", "-c", "onstat -g ses 2>/dev/null | head -n 200"], mutates=False)
    if onstat.rc != 0 or not onstat.stdout:
        return {"changed": False, "msg": "onstat not available / Informix not running", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = onstat.stdout.splitlines()
    idx = 0
    instance = None
    sessions = None
    while idx < len(lines):
        ln = lines[idx]
        parts = ln.split()
        if ln.find("[[[") == 0 and ln.find("]]]") > 0:
            end = ln.find("]]]")
            instance = ln[3:end]
        elif instance != None and len(parts) >= 2 and parts[0] == "SESSIONS":
            if parts[1].isdigit():
                sessions = int(parts[1])
                break
        idx = idx + 1
    if item != "" and instance != item:
        return {"changed": False, "msg": "no Informix instance '%s' found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sessions == None:
        return {"changed": False, "msg": "no session count available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sessions >= crit:
        state = "CRIT"
    elif sessions >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "Sessions: %d (warn/crit at %d/%d)" % (sessions, warn, crit), "data": {"state": state, "metrics": {"sessions": sessions}, "details": "Informix instance '%s' has %d active sessions" % (instance, sessions)}}