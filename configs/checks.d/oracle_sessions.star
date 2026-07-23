def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/dev/stdin"], mutates=False)
        section = {}
        lines = res.stdout.splitlines() if res.stdout else []
        for line in lines:
            parts = line.split()
            if len(parts) >= 2:
                sid = parts[0]
                cursess_str = parts[1]
                cursess = int(cursess_str) if cursess_str.isdigit() else None
                if cursess != None:
                    entry = {"cursess": cursess}
                    if len(parts) >= 3:
                        maxsess_str = parts[2]
                        if maxsess_str.isdigit():
                            entry["maxsess"] = int(maxsess_str)
                    if len(parts) >= 4:
                        curmax_str = parts[3]
                        if curmax_str.isdigit():
                            entry["curmax"] = int(curmax_str)
                    section[sid] = entry
        discovery = []
        for sid in section:
            discovery.append({"item": sid, "params": {"sessions_abs": [150, 300]}, "metrics": ["sessions"]})
        return {"changed": False, "msg": "discovered %d oracle instances" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/dev/stdin"], mutates=False)
    section = {}
    lines = res.stdout.splitlines() if res.stdout else []
    for line in lines:
        parts = line.split()
        if len(parts) >= 2:
            sid = parts[0]
            cursess_str = parts[1]
            cursess = int(cursess_str) if cursess_str.isdigit() else None
            if cursess != None:
                entry = {"cursess": cursess}
                if len(parts) >= 3:
                    maxsess_str = parts[2]
                    if maxsess_str.isdigit():
                        entry["maxsess"] = int(maxsess_str)
                if len(parts) >= 4:
                    curmax_str = parts[3]
                    if curmax_str.isdigit():
                        entry["curmax"] = int(curmax_str)
                section[sid] = entry

    data = section.get(item)
    if data == None or "cursess" not in data:
        return {"changed": False, "msg": "Login into database failed or instance not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sessions = data["cursess"]
    sessions_max = data.get("maxsess")
    
    # Extract thresholds from params with Checkmk defaults
    sessions_abs = params.get("sessions_abs", [150, 300])
    warn_abs = sessions_abs[0] if len(sessions_abs) >= 1 else 150
    crit_abs = sessions_abs[1] if len(sessions_abs) >= 2 else 300
    
    sessions_perc = None
    if sessions_max != None:
        sessions_perc = 100.0 * sessions / sessions_max
    
    # Determine state based on absolute thresholds
    state = "OK"
    if sessions >= crit_abs:
        state = "CRIT"
    elif sessions >= warn_abs:
        state = "WARN"
    
    # Check percentage levels if available
    if sessions_max != None:
        sessions_perc_param = params.get("sessions_perc", [])
        if len(sessions_perc_param) >= 2:
            warn_perc = sessions_perc_param[0]
            crit_perc = sessions_perc_param[1]
            if sessions_perc >= crit_perc:
                state = "CRIT"
            elif sessions_perc >= warn_perc and state != "CRIT":
                state = "WARN"
    
    # Build message
    msg = "Sessions: %d" % sessions
    if sessions_max != None:
        msg += " (Maximum: %d)" % sessions_max
    
    metrics = {"sessions": sessions}
    if sessions_max != None:
        metrics["sessions_max"] = sessions_max
        metrics["sessions_percent"] = sessions_perc
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}