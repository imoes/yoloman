def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["corosync-cfgtool", "-s"], mutates=False)
        if probe.rc == 127 or probe.rc != 0:
            return {"changed": False, "msg": "no corosync latency data", "data": {"discovery": []}}
        links = {}
        current_host = None
        lines = probe.stdout.splitlines()
        i = 0
        n = len(lines)
        while i < n:
            line = lines[i]
            i = i + 1
            if line.find("link connected") != -1 or line.find(" link ") != -1:
                if current_host != None:
                    pass
            if line.strip().startswith("link ") or line.strip().startswith("Link "):
                parts = line.split()
                if len(parts) >= 2:
                    link_name = parts[1]
                    host_part = line.strip()
                    links[current_host + "." + link_name] = {
                        "item": current_host + "." + link_name,
                        "params": {
                            "latency_max": params.get("latency_max", ("fixed", (5.0, 10.0))),
                            "latency_ave": params.get("latency_ave", ("fixed", (5.0, 10.0))),
                        },
                        "metrics": ["latency_max", "latency_ave", "latency_min"],
                    }
        if len(links) == 0:
            return {"changed": False, "msg": "no corosync latency data", "data": {"discovery": []}}
        discovery = []
        for k in links:
            discovery.append(links[k])
        return {"changed": False, "msg": "discovered %d links" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    probe = ctx.run(["corosync-cfgtool", "-s"], mutates=False)
    if probe.rc == 127 or probe.rc != 0:
        return {"changed": False, "msg": "corosync-cfgtool not available or failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse corosync-cfgtool -s output to find the link and latency stats
    # Format includes lines like:
    #   "link 0 (10.0.0.1): connected" and "link 0 (10.0.0.1): 0.000 sec total latency"
    host_name = item
    link_name = ""
    dot = item.find(".")
    if dot != -1:
        host_name = item[:dot]
        link_name = item[dot + 1:]

    found_latency_max = 0.0
    found_latency_ave = 0.0
    found_latency_min = 0.0
    connected = False
    found_item = False

    lines = probe.stdout.splitlines()
    for line in lines:
        if line.find("link " + link_name + " ") != -1 or line.find("link " + link_name + "\t") != -1:
            found_item = True
            if line.find("connected") != -1:
                connected = True
        if found_item and line.find("latency") != -1:
            # e.g. "link 0 (IP): 0.000123 sec average latency, 0.000456 sec max latency"
            # extract numbers
            nums = []
            parts = line.split()
            idx = 0
            while idx < len(parts):
                token = parts[idx]
                token_stripped = token
                if token_stripped == "sec":
                    idx = idx + 1
                    continue
                try_parse = token_stripped
                if try_parse == None or len(try_parse) == 0:
                    idx = idx + 1
                    continue
                is_num = True
                for ch in try_parse:
                    if ch != "." and not (ch >= "0" and ch <= "9") and ch != "-":
                        is_num = False
                        break
                if is_num:
                    nums.append(float(try_parse))
                idx = idx + 1
            if len(nums) >= 1:
                found_latency_ave = nums[0]
            if len(nums) >= 2:
                found_latency_max = nums[1]
            found_latency_min = nums[0] if len(nums) >= 1 else 0.0

    if not found_item:
        return {"changed": False, "msg": "link not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not connected:
        return {"changed": False, "msg": "Link is not connected or down", "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # latency values from corosync-cfgtool are already in seconds
    latency_max = found_latency_max
    latency_ave = found_latency_ave

    # Apply thresholds — params give ("fixed", (warn, crit))
    latency_max_levels = params.get("latency_max", ("fixed", (5.0, 10.0)))
    latency_ave_levels = params.get("latency_ave", ("fixed", (5.0, 10.0)))

    state_max = "OK"
    state_ave = "OK"

    if type(latency_max_levels) == "list" or type(latency_max_levels) == "tuple":
        if len(latency_max_levels) >= 2:
            level_type = latency_max_levels[0]
            if level_type == "fixed" and len(latency_max_levels) >= 2:
                warn_crit = latency_max_levels[1]
                if type(warn_crit) == "list" or type(warn_crit) == "tuple":
                    if len(warn_crit) >= 2:
                        warn_val = warn_crit[0]
                        crit_val = warn_crit[1]
                        if latency_max >= crit_val:
                            state_max = "CRIT"
                        elif latency_max >= warn_val:
                            state_max = "WARN"
                    elif len(warn_crit) == 1:
                        warn_val = warn_crit[0]
                        if latency_max >= warn_val:
                            state_max = "WARN"

    if type(latency_ave_levels) == "list" or type(latency_ave_levels) == "tuple":
        if len(latency_ave_levels) >= 2:
            level_type = latency_ave_levels[0]
            if level_type == "fixed" and len(latency_ave_levels) >= 2:
                warn_crit = latency_ave_levels[1]
                if type(warn_crit) == "list" or type(warn_crit) == "tuple":
                    if len(warn_crit) >= 2:
                        warn_val = warn_crit[0]
                        crit_val = warn_crit[1]
                        if latency_ave >= crit_val:
                            state_ave = "CRIT"
                        elif latency_ave >= warn_val:
                            state_ave = "WARN"
                    elif len(warn_crit) == 1:
                        warn_val = warn_crit[0]
                        if latency_ave >= warn_val:
                            state_ave = "WARN"

    overall_state = "OK"
    if state_max == "CRIT" or state_ave == "CRIT":
        overall_state = "CRIT"
    elif state_max == "WARN" or state_ave == "WARN":
        overall_state = "WARN"

    msg = "Latency Max: %s, Latency Ave: %s" % (_render_timespan(latency_max), _render_timespan(latency_ave))
    details = ""
    return {"changed": False, "msg": msg, "data": {"state": overall_state, "metrics": {"latency_max": latency_max, "latency_ave": latency_ave}, "details": details}}


def _render_timespan(seconds):
    if seconds < 1.0:
        return "%d ms" % int(seconds * 1000)
    return "%f s" % seconds