def _parse_kctune(output):
    parsed = {}
    key = ""
    usage = 0
    lines = output.splitlines()
    for line in lines:
        if len(line) < 2:
            continue
        first = line[0].strip()
        second = line[1].strip() if len(line) > 1 else ""
        if "Tunable" in first or "Parameter" in first:
            key = second
        elif "Usage" in first:
            usage = int(second) if second.isdigit() else 0
        elif "Setting" in first:
            threshold = int(second) if second.isdigit() else 0
            parsed[key] = (usage, threshold)
    return parsed

def _get_tunables(ctx):
    res = ctx.run(["kctune", "-q"], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    table = []
    for line in lines:
        parts = line.split()
        for i in range(len(parts)):
            if parts[i] in ("Tunable:", "Parameter:"):
                if i + 1 < len(parts):
                    table.append(["Tunable:", parts[i + 1]])

    res2 = ctx.run(["kctune", "-q", "-v"], mutates=False)
    if res2.rc != 0:
        return {}
    data_lines = res2.stdout.splitlines()
    parsed = {}
    key = ""
    usage = 0
    for line in data_lines:
        parts = line.split()
        for i in range(len(parts)):
            if parts[i] in ("Tunable:", "Parameter:"):
                if i + 1 < len(parts):
                    key = parts[i + 1]
            elif parts[i] == "Usage:":
                if i + 1 < len(parts):
                    usage = int(parts[i + 1]) if parts[i + 1].isdigit() else 0
            elif parts[i] == "Setting:":
                if i + 1 < len(parts):
                    threshold = int(parts[i + 1]) if parts[i + 1].isdigit() else 0
                    parsed[key] = (usage, threshold)
    return parsed

def main(ctx, params):
    if params.get("_discover"):
        section = _get_tunables(ctx)
        if section == None:
            return {"changed": False, "msg": "kctune not available", "data": {"discovery": []}}
        if "nkthread" in section:
            return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [
                {"item": "nkthread", "params": {"levels": (80.0, 85.0)}, "metrics": ["nkthread"]}
            ]}}
        return {"changed": False, "msg": "nkthread not found", "data": {"discovery": []}}

    item = params.get("item", "")
    section = _get_tunables(ctx)
    if section == None:
        return {"changed": False, "msg": "kctune not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if item not in section:
        return {"changed": False, "msg": item + " not found in tunables", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    usage, threshold = section[item]
    if threshold == 0:
        perc = 0.0
    else:
        perc = float(usage) / float(threshold) * 100

    levels = params.get("levels", (80.0, 85.0))
    warn = float(levels[0])
    crit = float(levels[1])

    state = "OK"
    if perc > crit:
        state = "CRIT"
    elif perc > warn:
        state = "WARN"

    msg = "%f%% used (%d/%d threads)" % (perc, usage, threshold)
    if state != "OK":
        msg = msg + " (warn/crit at %f/%f)" % (warn, crit)

    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"threads": usage}, "details": msg}}