def _probe_oracle_binary(ctx):
    for candidate in ["sqlplus", "sql", "sqlcl"]:
        res = ctx.run([candidate, "-v"], mutates=False)
        if res.rc == 127:
            continue
        if res.rc == 0 or res.rc == 1:
            return candidate
        return candidate
    return None

def _query_sys_time_model(ctx, binary, conn_str):
    sql = "set heading off feedback off verify off\n"
    sql += "select value from v$sys_time_model where stat_name='DB CPU';\n"
    sql += "select value from v$sys_time_model where stat_name='DB time';"
    script = "WHENEVER SQLERROR EXIT SQL.SQLCODE\n" + sql
    res = ctx.run([binary, "-S", conn_str], mutates=False, stdin=script)
    if res.rc != 0:
        return None
    return res.stdout

def _parse_two_values(output):
    lines = []
    for line in output.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        numeric = stripped.replace(".", "").replace("-", "")
        if numeric.isdigit():
            lines.append(int(stripped))
    if len(lines) >= 2:
        return lines[0], lines[1]
    return None, None

def _get_db_time_rates(ctx, item, binary, conn_str, prev_state):
    output = _query_sys_time_model(ctx, binary, conn_str)
    if output == None:
        return None, None, None, None

    db_cpu, db_time = _parse_two_values(output)
    if db_cpu == None or db_time == None:
        return None, None, None, None

    now = ctx.time()
    prev = prev_state.get(item)
    if prev == None:
        prev_state[item] = {"t": now, "cpu": db_cpu, "time": db_time}
        return db_cpu, db_time, None, now

    elapsed = now - prev["t"]
    if elapsed <= 0:
        return db_cpu, db_time, None, now

    cpu_rate = (db_cpu - prev["cpu"]) / elapsed
    time_rate = (db_time - prev["time"]) / elapsed
    wait_rate = time_rate - cpu_rate

    prev_state[item] = {"t": now, "cpu": db_cpu, "time": db_time}
    return cpu_rate, time_rate, wait_rate, now

def _check_thresholds(rate, metric_name, levels_map):
    levels = levels_map.get(metric_name)
    if levels == None:
        return "OK"
    warn = levels[0] if type(levels) == "list" else levels
    crit = levels[1] if type(levels) == "list" and len(levels) > 1 else None
    if crit != None and rate >= crit:
        return "CRIT"
    if warn != None and rate >= warn:
        return "WARN"
    return "OK"

def _fmt_rate(rate):
    return "%f" % rate

def main(ctx, params):
    if params.get("_discover"):
        binary = _probe_oracle_binary(ctx)
        if binary == None:
            return {"changed": False, "msg": "no Oracle client found",
                    "data": {"discovery": []}}

        host = params.get("host", "localhost")
        port = params.get("port", 1521)
        sid = params.get("sid", "ORCL")
        user = params.get("user", None)
        password = params.get("password", None)

        if user and password:
            conn_str = user + "/" + password + "@" + host + ":" + str(port) + "/" + sid
        else:
            conn_str = host + ":" + str(port) + "/" + sid

        output = _query_sys_time_model(ctx, binary, conn_str)
        if output == None:
            return {"changed": False, "msg": "no Oracle instance found",
                    "data": {"discovery": []}}

        db_cpu, db_time = _parse_two_values(output)
        if db_cpu == None or db_time == None:
            return {"changed": False, "msg": "could not read sys_time_model",
                    "data": {"discovery": []}}

        item = sid
        return {"changed": False,
                "msg": "discovered 1 Oracle instance: %s" % item,
                "data": {"discovery": [
                    {"item": item, "params": {}, "metrics": [
                        "oracle_db_time", "oracle_db_cpu", "oracle_db_wait_time"]},
                ]}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    port = params.get("port", 1521)
    sid = params.get("sid", "ORCL")
    user = params.get("user", None)
    password = params.get("password", None)

    binary = _probe_oracle_binary(ctx)
    if binary == None:
        return {"changed": False, "msg": "no Oracle client found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if user and password:
        conn_str = user + "/" + password + "@" + host + ":" + str(port) + "/" + sid
    else:
        conn_str = host + ":" + str(port) + "/" + sid

    prev_state = {}
    db_cpu, db_time, wait_time, now = _get_db_time_rates(
        ctx, item, binary, conn_str, prev_state)
    if db_cpu == None:
        return {"changed": False, "msg": "no Oracle instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if wait_time == None:
        return {"changed": False,
                "msg": "%s: collecting initial data (DB CPU: %s, DB time: %s)" % (
                    item, _fmt_rate(db_cpu), _fmt_rate(db_time)),
                "data": {"state": "OK", "metrics": {},
                         "details": "initial measurement — rate not yet available"}}

    metrics = {
        "oracle_db_time": db_time,
        "oracle_db_cpu": db_cpu,
        "oracle_db_wait_time": wait_time,
    }

    levels_map = params.get("levels", {})
    states = []
    labels = []
    for rate, metric_name, infoname in [
        (db_time, "oracle_db_time", "DB Time"),
        (db_cpu, "oracle_db_cpu", "DB CPU"),
        (wait_time, "oracle_db_wait_time", "DB Non-Idle Wait"),
    ]:
        states.append(_check_thresholds(rate, metric_name, levels_map))
        labels.append("%s: %s/s" % (infoname, _fmt_rate(rate)))

    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False, "msg": "; ".join(labels),
            "data": {"state": state, "metrics": metrics, "details": ""}}