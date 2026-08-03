def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["megacli", "--version"], mutates=False)
        if probe.rc == 127 or probe.rc != 0:
            return {"changed": False, "msg": "megacli not found", "data": {"discovery": [], "host_labels": {}}}

        res = ctx.run(["megacli", "-LDInfo", "-Lall", "-aALL"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "megacli failed", "data": {"discovery": []}}

        parsed = {}
        adapter = None
        disk = None
        item = None
        lines = res.stdout.splitlines()
        for line in lines:
            stripped = line.strip()
            l = stripped
            if not l:
                continue
            parts = l.split(" ")
            if parts[0] == "Adapter" and not l.endswith("No Virtual Drive Configured."):
                adapter = parts[1]
                disk = None
                item = None
            elif (l.startswith("Virtual Disk:") or l.startswith("Virtual Drive:") or l.startswith("CacheCade Virtual Drive:")) and adapter != None:
                disk = l.split(": ")[1].split(" ")[0]
                item = "/c" + adapter + "/v" + disk
                parsed[item] = {}
            elif item != None and item in parsed:
                if parts[0].startswith("State"):
                    parsed[item]["state"] = l.split(":")[1].strip()
                elif parts[0].startswith("Default"):
                    if len(parts) > 1 and parts[1].startswith("Cache"):
                        parsed[item]["default_cache"] = " ".join(parts[3:]).replace(": ", "")
                    elif len(parts) > 1 and parts[1].startswith("Write"):
                        parsed[item]["default_write"] = " ".join(parts[3:]).replace(": ", "")
                elif parts[0].startswith("Current"):
                    if len(parts) > 1 and parts[1].startswith("Cache"):
                        parsed[item]["current_cache"] = " ".join(parts[3:]).replace(": ", "")
                    elif len(parts) > 1 and parts[1].startswith("Write"):
                        parsed[item]["current_write"] = " ".join(parts[3:]).replace(": ", "")

        filtered = {}
        for k in parsed:
            if "state" in parsed[k]:
                filtered[k] = parsed[k]

        defaults_map = {"Optimal": 0, "Non-Optimal": 1, "RAIN": 1, "Offline": 2, "Partial": 2, "Dead": 2, "Failed": 2, "Rebuilding": 3, "Foreground Init In Progress": 3, "Background Init In Progress": 3, "Degraded": 3}

        out = []
        for it in filtered:
            if it.startswith("/c"):
                out.append({"item": it, "params": defaults_map, "metrics": []})

        return {"changed": False, "msg": "discovered %d RAID logical disks" % len(out), "data": {"discovery": out, "host_labels": {}}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    probe = ctx.run(["megacli", "--version"], mutates=False)
    if probe.rc == 127 or probe.rc != 0:
        return {"changed": False, "msg": "megacli not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": "megacli binary not found on host"}}

    res = ctx.run(["megacli", "-LDInfo", "-Lall", "-aALL"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "megacli failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": "megacli -LDInfo returned non-zero"}}

    parsed = {}
    adapter = None
    disk = None
    found_item = None
    lines = res.stdout.splitlines()
    for line in lines:
        stripped = line.strip()
        l = stripped
        if not l:
            continue
        parts = l.split(" ")
        if parts[0] == "Adapter" and not l.endswith("No Virtual Drive Configured."):
            adapter = parts[1]
            disk = None
            found_item = None
        elif (l.startswith("Virtual Disk:") or l.startswith("Virtual Drive:") or l.startswith("CacheCade Virtual Drive:")) and adapter != None:
            disk = l.split(": ")[1].split(" ")[0]
            found_item = "/c" + adapter + "/v" + disk
            parsed[found_item] = {}
        elif found_item != None and found_item in parsed:
            if parts[0].startswith("State"):
                parsed[found_item]["state"] = l.split(":")[1].strip()
            elif parts[0].startswith("Default"):
                if len(parts) > 1 and parts[1].startswith("Cache"):
                    parsed[found_item]["default_cache"] = " ".join(parts[3:]).replace(": ", "")
                elif len(parts) > 1 and parts[1].startswith("Write"):
                    parsed[found_item]["default_write"] = " ".join(parts[3:]).replace(": ", "")
            elif parts[0].startswith("Current"):
                if len(parts) > 1 and parts[1].startswith("Cache"):
                    parsed[found_item]["current_cache"] = " ".join(parts[3:]).replace(": ", "")
                elif len(parts) > 1 and parts[1].startswith("Write"):
                    parsed[found_item]["current_write"] = " ".join(parts[3:]).replace(": ", "")

    filtered = {}
    for k in parsed:
        if "state" in parsed[k]:
            filtered[k] = parsed[k]

    if item not in filtered:
        return {"changed": False, "msg": "RAID logical disk not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ld = filtered[item]
    st = ld["state"]

    defaults_map = {"Optimal": 0, "Non-Optimal": 1, "RAIN": 1, "Offline": 2, "Partial": 2, "Dead": 2, "Failed": 2, "Rebuilding": 3, "Foreground Init In Progress": 3, "Background Init In Progress": 3, "Degraded": 3}
    if st in params:
        level = params.get(st, 3)
    elif st in defaults_map:
        level = defaults_map.get(st, 3)
    else:
        level = 3

    if level == 0:
        state = "OK"
    elif level == 1:
        state = "WARN"
    elif level == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    summary = st.capitalize()
    details = ""

    if "default_cache" in ld and "current_cache" in ld:
        if ld["default_cache"] != ld["current_cache"]:
            details += "Cache policy: default=" + ld["default_cache"] + ", current=" + ld["current_cache"] + "\n"
    if "default_write" in ld and "current_write" in ld:
        if ld["default_write"] != ld["current_write"]:
            details += "Write policy: default=" + ld["default_write"] + ", current=" + ld["current_write"] + "\n"

    if details and state == "OK":
        state = "WARN"

    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {}, "details": details.strip()}}