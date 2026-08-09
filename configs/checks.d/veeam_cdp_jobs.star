def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["veeam_cdp_jobs"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to retrieve VEEAM CDP jobs data",
                    "data": {"discovery": []}}
        jobs = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(",")
            if len(parts) != 3:
                continue
            name = parts[0].strip().strip('"')
            if not name:
                continue
            jobs.append({"item": name, "params": {"age": [108000, 172800]},
                         "metrics": ["last_sync_seconds"]})
        return {"changed": False, "msg": "discovered %d CDP jobs" % len(jobs),
                "data": {"discovery": jobs}}
    item = params.get("item", "")
    res = ctx.run(["veeam_cdp_jobs"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to retrieve VEEAM CDP jobs data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Parse section: map name -> (last_sync_timestamp, state_str)
    section = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(",")
        if len(parts) != 3:
            continue
        name = parts[0].strip().strip('"')
        if not name:
            continue
        last_sync_str = parts[1].strip()
        state_str = parts[2].strip()
        # Convert comma decimal separator to dot for float conversion
        last_sync_str = last_sync_str.replace(",", ".")
        # "null" means no timestamp
        last_sync = float(last_sync_str) if last_sync_str != "null" else None
        section[name] = (last_sync, state_str)

    cdp = section.get(item)
    if cdp == None:
        return {"changed": False, "msg": "job not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    last_sync, state_str = cdp

    # Map states
    state_map = {
        "Running": "OK",
        "Failed": "CRIT",
        "Stopped": "CRIT",
        "Disabled": "OK",
        "null": "UNKNOWN",
        "": "UNKNOWN"
    }
    state = state_map.get(state_str, "UNKNOWN")

    # Build summary
    summary = "State: %s" % state_str

    # Time-since-last-sync check
    metrics = {}
    if last_sync != None:
        now = ctx.run(["date", "+%s"], mutates=False)
        if now.rc == 0 and now.stdout.strip().isdigit():
            now_ts = int(now.stdout.strip())
            time_diff = now_ts - last_sync
            metrics["last_sync_seconds"] = time_diff
            if time_diff < 0:
                summary += "; The timestamp of the file is in the future. Please investigate your host times"
                state = "WARN"
            else:
                warn, crit = params.get("age", [108000, 172800])
                if crit != None and time_diff >= crit:
                    state = "CRIT"
                elif warn != None and time_diff >= warn:
                    state = "WARN"
                # Format seconds to human-readable string
                def fmt(s):
                    s = int(s)
                    d = s // 86400
                    h = (s % 86400) // 3600
                    m = (s % 3600) // 60
                    sec = s % 60
                    parts = []
                    if d:
                        parts.append("%d d" % d)
                    if h or d:
                        parts.append("%d h" % h)
                    if m or h or d:
                        parts.append("%d m" % m)
                    parts.append("%d s" % sec)
                    return " ".join(parts)
                summary += "; Time since last CDP Run: %s" % fmt(time_diff)
        else:
            summary += "; Time since last CDP Run: unknown (time probe failed)"

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}
