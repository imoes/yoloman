def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snap7", "--version"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "siemens_plc not installed (snap7 tooling missing)", "data": {"discovery": []}}
        
        res = ctx.run(["snap7", "-read", "siemens_plc"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snap7 read failed", "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        out = []
        for line in lines:
            f = line.split()
            if len(f) < 4:
                continue
            kind = f[1]
            if kind.startswith("hours") or kind.startswith("seconds"):
                item = f[0] + " " + f[2]
                out.append({"item": item, "params": {}, "metrics": [kind]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["snap7", "--version"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "snap7 not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run(["snap7", "-read", "siemens_plc"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snap7 read failed: " + res.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    for line in lines:
        f = line.split()
        if len(f) < 4:
            continue
        kind = f[1]
        if (kind.startswith("hours") or kind.startswith("seconds")) and (f[0] + " " + f[2]) == item:
            value = float(f[-1])
            if kind.startswith("hours"):
                seconds = value * 3600
            else:
                seconds = value
            
            warn = params.get("warn")
            crit = params.get("crit")
            if warn == None and crit == None:
                levels = params.get("levels")
                if levels != None and len(levels) >= 2:
                    warn = levels[0]
                    crit = levels[1]
            
            if warn != None and crit != None:
                if seconds >= crit:
                    state = "CRIT"
                elif seconds >= warn:
                    state = "WARN"
                else:
                    state = "OK"
            elif params.get("duration") != None:
                dur = params.get("duration")
                d_warn = dur.get("warn")
                d_crit = dur.get("crit")
                if d_crit != None and seconds >= d_crit:
                    state = "CRIT"
                elif d_warn != None and seconds >= d_warn:
                    state = "WARN"
                else:
                    state = "OK"
            else:
                state = "OK"
            
            return {"changed": False, "msg": "%s %d seconds" % (item, int(seconds)), "data": {"state": state, "metrics": {kind: seconds}, "details": ""}}
    
    return {"changed": False, "msg": "item " + item + " not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}