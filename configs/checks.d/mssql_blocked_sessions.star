def main(ctx, params):
    # Discovery mode: enumerate MSSQL instances with blocked sessions data
    if params.get("_discover"):
        # Check for sqlcmd availability
        res = ctx.run(["which", "sqlcmd"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items (sqlcmd not installed)",
                    "data": {"discovery": []}}

        # Run the T-SQL query to get blocked sessions
        query = "SELECT DB_NAME(database_id), session_id, wait_duration_ms, wait_type, blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id IS NOT NULL"
        res = ctx.run(["sqlcmd", "-S", "localhost", "-Q", query, "-h", "-1", "-W"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items (query failed or no blocked sessions)",
                    "data": {"discovery": []}}

        # Parse the T-SQL output into instances
        parsed = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or line.startswith("ERROR:"):
                continue
            parts = line.split()
            if len(parts) != 5:
                continue
            inst = parts[0]
            session_id = parts[1]
            wait_duration_ms = parts[2]
            wait_type = parts[3]
            blocking_session_id = parts[4]

            # Validate numeric fields using guards instead of try/except
            if not session_id.isdigit() or not blocking_session_id.isdigit():
                continue
            # Handle wait_duration_ms: could be integer or float (with decimal point)
            wdm_str = wait_duration_ms
            if wdm_str.find('.') != -1:
                # Check for valid float format: digits, one dot, digits
                parts_float = wdm_str.split('.')
                if len(parts_float) != 2 or not parts_float[0].isdigit() or not parts_float[1].isdigit():
                    continue
                wdm = float(wdm_str)
            else:
                if not wdm_str.isdigit():
                    continue
                wdm = float(wdm_str)

            sid = int(session_id)
            bid = int(blocking_session_id)

            instance_data = parsed.setdefault(inst, [])
            instance_data.append({
                "session_id": str(sid),
                "wait_type": wait_type,
                "blocking_session_id": str(bid),
                "wait_duration_ms": wdm,
            })

        # Build discovery list: one entry per instance
        out = []
        for inst in parsed:
            if parsed[inst]:
                out.append({
                    "item": inst,
                    "params": {"state": 2, "waittime": [None, None]},
                    "metrics": ["blocked_sessions_count", "max_wait_time"],
                })
        return {"changed": False, "msg": "discovered %d instances" % len(out),
                "data": {"discovery": out}}

    # Check mode: one instance
    item = params.get("item", "")
    # Check for sqlcmd availability
    res = ctx.run(["which", "sqlcmd"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "sqlcmd not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    query = "SELECT DB_NAME(database_id), session_id, wait_duration_ms, wait_type, blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id IS NOT NULL"
    res = ctx.run(["sqlcmd", "-S", "localhost", "-Q", query, "-h", "-1", "-W"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "Failed to retrieve data from database",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse into instance -> list
    parsed = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("ERROR:"):
            continue
        parts = line.split()
        if len(parts) != 5:
            continue
        inst = parts[0]
        session_id = parts[1]
        wait_duration_ms = parts[2]
        wait_type = parts[3]
        blocking_session_id = parts[4]

        # Validate numeric fields using guards instead of try/except
        if not session_id.isdigit() or not blocking_session_id.isdigit():
            continue
        # Handle wait_duration_ms: could be integer or float
        wdm_str = wait_duration_ms
        if wdm_str.find('.') != -1:
            parts_float = wdm_str.split('.')
            if len(parts_float) != 2 or not parts_float[0].isdigit() or not parts_float[1].isdigit():
                continue
            wdm = float(wdm_str)
        else:
            if not wdm_str.isdigit():
                continue
            wdm = float(wdm_str)

        sid = int(session_id)
        bid = int(blocking_session_id)

        instance_data = parsed.setdefault(inst, [])
        instance_data.append({
            "session_id": str(sid),
            "wait_type": wait_type,
            "blocking_session_id": str(bid),
            "wait_duration_ms": wdm,
        })

    # Check item existence
    if item not in parsed:
        return {"changed": False, "msg": "Failed to retrieve data from database",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = parsed[item]
    if not data:
        return {"changed": False, "msg": "No blocking sessions",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    # Process parameters
    waittime = params.get("waittime", [None, None])
    warn = waittime[0]
    crit = waittime[1]
    ignored_waittypes = set(params.get("ignore_waittypes", []))
    default_state = params.get("state", 2)
    if default_state not in (0, 1, 2, 3):
        default_state = 2

    # Build list of details and count blocked sessions per blocking session
    blocked_sessions_counter = {}  # key: blocking_session_id, value: set of session_ids blocked by it
    max_wait_time = 0.0

    for db_inst in data:
        wait_type = db_inst["wait_type"]
        if wait_type in ignored_waittypes:
            continue

        duration_sec = db_inst["wait_duration_ms"] / 1000.0
        if duration_sec > max_wait_time:
            max_wait_time = duration_sec

        # Check levels if waittime is configured (both warn and crit not None)
        state_detail = "OK"
        if crit != None and warn != None:
            # Check against upper levels
            if duration_sec >= crit:
                state_detail = "CRIT"
            elif duration_sec >= warn:
                state_detail = "WARN"
            else:
                state_detail = "OK"
        else:
            # Without levels, use default state for any blocking session
            state_detail = ("OK", "WARN", "CRIT", "UNKNOWN")[default_state]

        # Build details summary
        details_summary = "Session %s blocked by %s, Type: %s, Wait: %f s" % (
            db_inst["session_id"], db_inst["blocking_session_id"], wait_type, duration_sec
        )

        # Count per blocking session
        bid = db_inst["blocking_session_id"]
        if bid not in blocked_sessions_counter:
            blocked_sessions_counter[bid] = set()
        blocked_sessions_counter[bid].add(db_inst["session_id"])

    # Overall state logic
    if crit != None and warn != None:
        state = "OK"
    else:
        state = ("OK", "WARN", "CRIT", "UNKNOWN")[default_state]

    # Build summary: "Summary: <session_id> blocked by <blocking_session_id> ID(s)"
    summary_parts = []
    for bid, sessions in sorted(blocked_sessions_counter.items()):
        summary_parts.append("%s blocked by %s ID(s)" % (", ".join(sorted(sessions)), bid))
    summary = "Summary: " + ", ".join(summary_parts) if summary_parts else ""

    # Build msg
    msg_parts = []
    if summary:
        msg_parts.append(summary)
    # Add ignored wait types if any
    ignored_set = set()
    for db_inst in data:
        if db_inst["wait_type"] in ignored_waittypes:
            ignored_set.add(db_inst["wait_type"])
    if ignored_set:
        msg_parts.append("Ignored wait types: " + ", ".join(sorted(ignored_set)))

    msg = "; ".join(msg_parts) if msg_parts else "No blocking sessions"
    if not summary_parts:
        msg = "No blocking sessions"

    # Metrics: blocked_sessions_count = number of blocking sessions; max_wait_time
    metrics = {
        "blocked_sessions_count": len(blocked_sessions_counter),
        "max_wait_time": max_wait_time,
    }

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}