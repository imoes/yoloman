# Constants for state mapping
_STATE_MAP = {
    "1": ("OK", "Normal"),
    "2": ("WARN", "Degraded"),
    "3": ("CRIT", "Failed"),
}

def _count_vvs(sa_num, sd_num, usr_num):
    return sa_num + sd_num + usr_num

def _get_cpg_by_item(section, item):
    parts = item.rsplit(" ", 1)
    if len(parts) != 2:
        return None, None
    cpg_name = parts[0]
    usage_type = parts[1]
    if cpg_name not in section:
        return None, None
    cpg = section.get(cpg_name)
    if usage_type == "SAUsage":
        usage = cpg.get("sa_usage")
    elif usage_type == "SDUsage":
        usage = cpg.get("sd_usage")
    elif usage_type == "UsrUsage":
        usage = cpg.get("usr_usage")
    else:
        return None, None
    return cpg, usage

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "http://localhost:8080/api/v1/cpg"], mutates=False)
        if res.rc != 0:
            res = ctx.run(["wget", "-q", "-O", "-", "http://localhost:8080/api/v1/cpg"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no CPG data available", "data": {"discovery": []}}
        
        if res.stdout == None or res.stdout == "":
            return {"changed": False, "msg": "no CPG data available", "data": {"discovery": []}}
        
        data = json.decode(res.stdout)
        
        members = data.get("members", [])
        out = []
        for cpg in members:
            name = cpg.get("name", "")
            num_fpvvs = cpg.get("numFPVVs", 0)
            num_tdvvs = cpg.get("numTDVVs", 0)
            num_tpvvs = cpg.get("numTPVVs", 0)
            if _count_vvs(num_fpvvs, num_tdvvs, num_tpvvs) > 0:
                for fs in ["SAUsage", "SDUsage", "UsrUsage"]:
                    out.append({
                        "item": name + " " + fs,
                        "params": {"levels": (80.0, 90.0)},
                        "metrics": ["used_percent"]
                    })
        return {"changed": False, "msg": "discovered %d CPG usages" % len(out), "data": {"discovery": out}}
    
    item = params.get("item", "")
    if item == None:
        item = ""
    if item == "":
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run(["curl", "-s", "http://localhost:8080/api/v1/cpg"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["wget", "-q", "-O", "-", "http://localhost:8080/api/v1/cpg"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no CPG data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if res.stdout == None or res.stdout == "":
        return {"changed": False, "msg": "no CPG data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    
    members = data.get("members", [])
    section = {}
    for cpg in members:
        name = cpg.get("name", "")
        num_fpvvs = cpg.get("numFPVVs", 0)
        num_tdvvs = cpg.get("numTDVVs", 0)
        num_tpvvs = cpg.get("numTPVVs", 0)
        sa_usage = cpg.get("SAUsage", {})
        sd_usage = cpg.get("SDUsage", {})
        usr_usage = cpg.get("UsrUsage", {})
        section[name] = {
            "state": cpg.get("state", 0),
            "num_fpvvs": num_fpvvs,
            "num_tdvvs": num_tdvvs,
            "num_tpvvs": num_tpvvs,
            "sa_usage": sa_usage,
            "sd_usage": sd_usage,
            "usr_usage": usr_usage,
        }
    
    cpg_data, usage = _get_cpg_by_item(section, item)
    if cpg_data == None or usage == None:
        return {"changed": False, "msg": "CPG or usage not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    total_mib = usage.get("totalMiB", 0.0)
    used_mib = usage.get("usedMiB", 0.0)
    if total_mib <= 0:
        return {"changed": False, "msg": "invalid total size: " + str(total_mib), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    free_mib = total_mib - used_mib
    
    levels = params.get("levels")
    if levels != None and type(levels) == "list":
        if len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]
        else:
            warn = params.get("warn", 80.0)
            crit = params.get("crit", 90.0)
    else:
        warn = params.get("warn", 80.0)
        crit = params.get("crit", 90.0)
    
    used_percent = (used_mib / total_mib) * 100.0
    
    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    
    cpg_state_code = str(cpg_data.get("state", 1))
    state_tuple = _STATE_MAP.get(cpg_state_code, ("UNKNOWN", "Unknown"))
    cpg_state_str = state_tuple[1]
    num_vvs = _count_vvs(cpg_data.get("num_fpvvs", 0), cpg_data.get("num_tdvvs", 0), cpg_data.get("num_tpvvs", 0))
    
    msg = "%s, %d VVs, Size: %f MiB, Used: %f MiB (%f%%)" % (
        cpg_state_str, num_vvs, total_mib, used_mib, used_percent
    )
    
    metrics = {
        "used_percent": used_percent,
        "used": used_mib,
        "free": free_mib,
        "total": total_mib,
    }
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }