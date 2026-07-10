def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cmk-agent-ctl", "list-sections"], mutates=False)
        if "3par_cpgs" not in res.stdout:
            return {"changed": False, "msg": "discovered 0 CPG sections"}
        res = ctx.run(["cmk", "-d", ctx.facts().get("hostname", "")], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 CPG sections"}
        agent_data = json.decode(res.stdout)
        raw_members = agent_data.get("members", []) if type(agent_data) == "dict" else []
        cpgs = []
        for member in raw_members:
            if type(member) != "dict":
                continue
            name = member.get("name", "")
            num_fpvvs = member.get("numFPVVs", 0) or 0
            num_tdvvs = member.get("numTDVVs", 0) or 0
            num_tpvvs = member.get("numTPVVs", 0) or 0
            if name and (int(num_fpvvs) + int(num_tdvvs) + int(num_tpvvs)) > 0:
                cpgs.append({"name": name, "num_fpvvs": int(num_fpvvs),
                             "num_tdvvs": int(num_tdvvs), "num_tpvvs": int(num_tpvvs)})
        out = []
        for cpg in cpgs:
            for fs in ["SAUsage", "SDUsage", "UsrUsage"]:
                out.append({
                    "item": cpg["name"] + " " + fs,
                    "params": {"levels": (80.0, 90.0)},
                    "metrics": ["used_percent"]
                })
        return {"changed": False, "msg": "discovered %d CPG usage items" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    parts = item.split(" ", 1)
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cpg_name = parts[0]
    usage_type = parts[1]
    if usage_type not in ["SAUsage", "SDUsage", "UsrUsage"]:
        return {"changed": False, "msg": "unknown usage type: " + usage_type,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run(["cmk", "-d", ctx.facts().get("hostname", "")], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "could not retrieve agent data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    agent_data = json.decode(res.stdout)
    raw_members = agent_data.get("members", []) if type(agent_data) == "dict" else []
    cpg = None
    for member in raw_members:
        if type(member) == "dict" and member.get("name") == cpg_name:
            cpg = member
            break
    if cpg == None:
        return {"changed": False, "msg": "CPG not found: " + cpg_name,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    usage_map = {
        "SAUsage": "SAUsage",
        "SDUsage": "SDUsage",
        "UsrUsage": "UsrUsage"
    }
    usage_key = usage_map.get(usage_type)
    usage = cpg.get(usage_key)
    if usage == None:
        return {"changed": False, "msg": usage_type + " not found in CPG " + cpg_name,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    totalMiB = usage.get("totalMiB", 0)
    usedMiB = usage.get("usedMiB", 0)
    # Convert to float using int/float coercion; fail on non-numeric
    if type(totalMiB) == "int":
        totalMiB = float(totalMiB)
    elif type(totalMiB) == "string":
        if totalMiB.isdigit():
            totalMiB = float(int(totalMiB))
        else:
            fail("non-numeric totalMiB value")
    else:
        totalMiB = float(totalMiB)
    if type(usedMiB) == "int":
        usedMiB = float(usedMiB)
    elif type(usedMiB) == "string":
        if usedMiB.isdigit():
            usedMiB = float(int(usedMiB))
        else:
            fail("non-numeric usedMiB value")
    else:
        usedMiB = float(usedMiB)
    if totalMiB > 0:
        used_percent = (usedMiB / totalMiB) * 100.0
    else:
        used_percent = 0.0
    warn = params.get("levels", (80.0, 90.0))
    warn_val = warn[0] if type(warn) == "list" else 80.0
    crit_val = warn[1] if type(warn) == "list" else 90.0
    state = "CRIT" if used_percent >= crit_val else ("WARN" if used_percent >= warn_val else "OK")
    state_str = "OK" if state == "OK" else ("WARNING" if state == "WARN" else "CRITICAL")
    size_str = "%.2f MiB" % totalMiB
    used_str = "%.2f MiB" % usedMiB
    return {
        "changed": False,
        "msg": "%s: %s (%s total, %s used)" % (usage_type, state_str, size_str, used_str),
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent, "size": totalMiB, "used": usedMiB},
            "details": ""
        }
    }
