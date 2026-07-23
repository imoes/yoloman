def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/dpkg/status", "/proc/driver/unitrends_backup", "/opt/unitrends/backup/status"], mutates=False)
        # Try to read the agent output file if it exists; otherwise assume inline
        # In Checkmk agent, this section is provided as <<<unitrends_backup:sep(124)>>>
        # We'll check for a specific path used by unitrends; fallback to generic path.
        # Since we cannot know exact file path in generic agent mode, try common locations.
        # If ctx.run fails, we return empty discovery (no such backup data)
        # Instead, read agent section from agent output: the agent sends it as <<<unitrends_backup:sep(124)>>>
        # In Starlark runtime for Checkmk, agent sections are available via ctx.agent_section("unitrends_backup")
        # But this Starlark runtime does NOT expose agent sections — only ctx.run for commands.
        # Since the check source uses AgentSection/parse, we must simulate by reading the expected raw file.

        # However, per the problem, the check is for unitrends_backup and the agent section is provided.
        # In the absence of direct agent section access in Starlark runtime, we assume the agent has written
        # the section data to a known path. Unitrends often uses /var/log/unitrends/backup.log or similar.
        # Let's try a known file: /opt/unitrends/backup/status (common in Unitrends appliances).
        res = ctx.run(["cat", "/opt/unitrends/backup/status"], mutates=False)
        if res.rc != 0 or not res.stdout:
            # Try alternate path
            res = ctx.run(["cat", "/var/log/unitrends/backup/status"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 schedules",
                    "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        items = []
        for line in lines:
            parts = line.split("|")
            if len(parts) >= 5 and parts[0] == "HEADER":
                items.append({
                    "item": parts[1],
                    "params": {},
                    "metrics": []
                })

        return {"changed": False, "msg": "discovered %d schedules" % len(items),
                "data": {"discovery": items}}

    # Check mode (not discovery)
    item = params.get("item", "")
    if item == None:
        item = ""

    # Read agent output file (same as discovery, but we need to re-read since no state persistence)
    res = ctx.run(["cat", "/opt/unitrends/backup/status"], mutates=False)
    if res.rc != 0 or not res.stdout:
        res = ctx.run(["cat", "/var/log/unitrends/backup/status"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "Schedule not found in Agent Output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    message = None
    failures = ""
    details = []

    for line in lines:
        parts = line.split("|")
        if len(parts) < 5:
            continue

        if parts[0] == "HEADER":
            if message != None:
                # We have collected details already, break
                break
            if parts[1] == item:
                # Extract: _head, sched_name, app_name, sched_desc, failures
                sched_name = parts[1]
                app_name = parts[2]
                sched_desc = parts[3]
                failures = parts[4]
                message = "%s Errors in last 24/h for Application %s (%s)" % (failures, app_name, sched_desc)
            # else: not our item, keep looking
        else:
            # Detail line: app_type, bid, backup_type, status
            if message != None:
                app_type, bid, backup_type, status = parts[0], parts[1], parts[2], parts[3]
                details.append("Application Type: %s (%s), %s: %s" % (app_type, bid, backup_type, status))

    if message == None:
        return {"changed": False, "msg": "Schedule not found in Agent Output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Assemble full message
    full_msg = message
    if details:
        full_msg += "\n" + "\n".join(details)

    state = "CRIT" if failures != "0" else "OK"
    return {"changed": False, "msg": full_msg,
            "data": {"state": state, "metrics": {"failures": int(failures) if failures.isdigit() else 0}, "details": ""}}
