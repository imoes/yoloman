def main(ctx, params):
    if params.get("_discover"):
        # Probe for sqlcmd availability
        probe = ctx.run(["sqlcmd", "-?", "-o", "stdout"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "sqlcmd not found", "data": {"discovery": []}}

        # Discover MSSQL instances - query for available databases/instances
        # The agent plugin queries each configured instance; here we probe
        # default localhost instance with connection test
        instances = _discover_instances(ctx, probe)
        if not instances:
            return {"changed": False, "msg": "no MSSQL instances found",
                    "data": {"discovery": []}}

        discovery = []
        for inst in instances:
            discovery.append({"item": inst, "params": {}, "metrics": ["blocked_sessions"]})

        return {"changed": False,
                "msg": "discovered %d MSSQL instances" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False,
                "msg": "MSSQL agent plugin prior to version 1.6 not supported. " +
                       "Please upgrade your agent plugin (see Werk 6140)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = _query_blocked_sessions(ctx, item)
    if data == None:
        return {"changed": False, "msg": "Failed to retrieve data from database",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not data:
        return {"changed": False, "msg": "No blocking sessions",
                "data": {"state": "OK", "metrics": {"blocked_sessions": 0}, "details": ""}}

    waittime = params.get("waittime", None)
    warn = None
    crit = None
    if waittime != None and len(waittime) >= 2:
        warn = waittime[0]
        crit = waittime[1]

    ignored_waittypes = set(params.get("ignore_waittypes", []))
    state_param = params.get("state", 2)
    check_type = "count"
    if crit != None and warn != None:
        check_type = "waittime"

    blocked_sessions_counter = {}
    details = []
    ignored = set()

    for db_inst in data:
        if db_inst["wait_type"] in ignored_waittypes:
            ignored.add(db_inst["wait_type"])
            continue

        duration = db_inst["wait_duration"]
        inst_state = "OK"
        if check_type == "waittime":
            if crit != None and duration >= crit:
                inst_state = "CRIT"
            elif warn != None and duration >= warn:
                inst_state = "WARN"

        counter = blocked_sessions_counter.get(db_inst["session_id"], 0)
        blocked_sessions_counter[db_inst["session_id"]] = counter + 1

        label = "Session %s blocked by %s, Type: %s, Wait %s" % (
            db_inst["session_id"], db_inst["blocking_session_id"],
            db_inst["wait_type"], _render_timespan(duration))
        details.append(label)

    summary = ""
    if blocked_sessions_counter:
        parts = []
        for k in sorted(blocked_sessions_counter):
            parts.append("%s blocked by %s ID(s)" % (k, blocked_sessions_counter[k]))
        summary = "Summary: " + ", ".join(parts)
        state = _state_from_int(state_param) if check_type == "count" else "OK"
    else:
        summary = "No blocking sessions"
        state = "OK"

    if ignored:
        details.append("Ignored wait types: " + ", ".join(sorted(ignored)))

    metrics = {"blocked_sessions": len(data)}
    msg = summary if summary else "No blocking sessions"
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics,
                     "details": "; ".join(details) if details else ""}}


def _discover_instances(ctx, probe):
    # Try connecting to default instance on localhost
    # The agent plugin uses configured server list; we probe localhost
    query = _mssql_query("SELECT @@SERVERNAME")
    res = _sqlcmd_exec(ctx, "localhost", "master", query)
    if res.rc != 0:
        # Try common default - return localhost if connection works with any db
        return _try_default_instances(ctx)
    name = res.stdout.strip()
    if name:
        return [name]
    return []


def _try_default_instances(ctx):
    query = "SELECT @@SERVERNAME"
    for server in ["localhost", "127.0.0.1"]:
        res = _sqlcmd_exec(ctx, server, "master", query)
        if res.rc == 0 and res.stdout.strip():
            return [res.stdout.strip()]
    return []


def _sqlcmd_exec(ctx, server, database, query):
    argv = [
        "sqlcmd", "-S", server, "-d", database, "-Q", query,
        "-h", "-1", "-W", "-s", "|", "-o", "stdout"
    ]
    return ctx.run(argv, mutates=False)


def _mssql_query(field):
    # SQL query to get blocked sessions with wait info
    # Returns: instance_name, session_id, wait_duration_ms, wait_type, blocking_session_id
    q = ("SET NOCOUNT ON; " +
         "SELECT @@SERVERNAME, s.session_id, " +
         "ISNULL(s.wait_duration_ms, 0), " +
         "ISNULL(s.wait_type, ''), " +
         "ISNULL(s.blocking_session_id, '') " +
         "FROM sys.dm_exec_requests s " +
         "WHERE s.blocking_session_id <> 0 " +
         "AND s.blocking_session_id IS NOT NULL; " +
         "IF @@ROWCOUNT = 0 PRINT 'No blocking sessions'")
    return q


def _query_blocked_sessions(ctx, instance):
    query = _mssql_query("")
    res = _sqlcmd_exec(ctx, instance, "master", query)
    if res.rc != 0:
        return None

    lines = res.stdout.splitlines()
    data = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("ERROR:"):
            continue
        if stripped == "No blocking sessions":
            continue
        parts = stripped.split("|")
        if len(parts) < 5:
            continue
        inst = parts[0].strip()
        session_id = parts[1].strip()
        wait_ms = parts[2].strip()
        wait_type = parts[3].strip()
        blocking_id = parts[4].strip()
        if wait_type == "No blocking sessions":
            continue
        wait_duration = _safe_float(wait_ms)
        if wait_duration == None:
            wait_duration = 0.0
        data.append({
            "session_id": session_id,
            "wait_type": wait_type,
            "blocking_session_id": blocking_id,
            "wait_duration": wait_duration,
        })

    return data


def _safe_float(s):
    val = s
    if val.startswith("-"):
        val = val[1:]
    if val == "" or val == None:
        return None
    dot = False
    for c in val:
        if c == ".":
            if dot:
                return None
            dot = True
        elif c < "0" or c > "9":
            return None
    return float(val)


def _render_timespan(seconds):
    if seconds < 60:
        return "%fs" % seconds
    if seconds < 3600:
        mins = int(seconds / 60)
        secs = int(seconds - mins * 60)
        return "%dm %ds" % (mins, secs)
    hours = int(seconds / 3600)
    rem = seconds - hours * 3600
    mins = int(rem / 60)
    secs = int(rem - mins * 60)
    return "%dh %dm %ds" % (hours, mins, secs)


def _state_from_int(n):
    if n == 0:
        return "OK"
    if n == 1:
        return "WARN"
    if n == 2:
        return "CRIT"
    if n == 3:
        return "UNKNOWN"
    return "UNKNOWN"