def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mssql_counters"], mutates=False)
        if res.rc != 0 or res.stdout.strip() == "":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        if res.stdout.strip() == "":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        if type(data) != "dict":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        section = data.get("mssql_counters", {})
        if type(section) != "dict":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        out = []
        for key in section:
            counters = section.get(key)
            if type(counters) == "dict" and counters.get("page_life_expectancy") != None:
                parts = key.split("|")
                obj = parts[0] if len(parts) > 0 else ""
                instance = parts[1] if len(parts) > 1 else "None"
                item = (
                    obj + " page_life_expectancy"
                    if instance == "None"
                    else obj + " " + instance + " page_life_expectancy"
                )
                out.append({"item": item, "params": {"mssql_min_page_life_expectancy": [350, 300]},
                            "metrics": ["page_life_expectancy"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    parts = item.split()
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item format: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    obj = parts[0]
    instance = "None"
    if len(parts) >= 3:
        instance = parts[1]
    key = obj + "|" + instance
    
    res = ctx.run(["mssql_counters"], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "cannot read mssql_counters data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if type(data) != "dict":
        return {"changed": False, "msg": "invalid mssql_counters format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = data.get("mssql_counters", {})
    if type(section) != "dict":
        return {"changed": False, "msg": "invalid mssql_counters format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    counters = section.get(key, {})
    if type(counters) != "dict":
        return {"changed": False, "msg": "no data for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    page_life_expectancy = counters.get("page_life_expectancy")
    if page_life_expectancy == None:
        return {"changed": False, "msg": "no page_life_expectancy for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    levels = params.get("mssql_min_page_life_expectancy", [350, 300])
    warn = levels[0] if len(levels) >= 1 else 350
    crit = levels[1] if len(levels) >= 2 else 300
    
    pval = float(page_life_expectancy)
    
    state = "OK"
    if pval <= crit:
        state = "CRIT"
    elif pval <= warn:
        state = "WARN"
    
    seconds = int(pval)
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    parts_ts = []
    if days > 0:
        parts_ts.append("%d day" % days if days == 1 else "%d days" % days)
    if hours > 0:
        parts_ts.append("%d hour" % hours if hours == 1 else "%d hours" % hours)
    if minutes > 0:
        parts_ts.append("%d min" % minutes)
    if secs > 0 and len(parts_ts) == 0:
        parts_ts.append("%d sec" % secs)
    summary = " ".join(parts_ts) if len(parts_ts) > 0 else "0 sec"
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"page_life_expectancy": pval}, "details": ""}}