def _format_bytes(n):
    n = int(n)
    if n < 1024:
        return "%d B" % n
    if n < 1048576:
        return "%f KB" % (float(n) / 1024.0)
    if n < 1073741824:
        return "%f MB" % (float(n) / 1048576.0)
    if n < 1099511627776:
        return "%f GB" % (float(n) / 1073741824.0)
    return "%f TB" % (float(n) / 1099511627776.0)

def _format_timespan(secs):
    secs = int(secs)
    if secs < 0:
        secs = 0
    if secs < 60:
        return "%d seconds" % secs
    if secs < 3600:
        return "%d minutes %d seconds" % (secs // 60, secs % 60)
    if secs < 86400:
        return "%d hours %d minutes" % (secs // 3600, (secs % 3600) // 60)
    return "%d days %d hours" % (secs // 86400, (secs % 86400) // 3600)

def _int_or(v, default):
    return int(v) if v != None else default

EVAL_SCRIPT = "var i=db.getReplicationInfo();" + \
    "if(i.errmsg){print(JSON.stringify({error:i.errmsg}))}" + \
    "else{" + \
    "var tf=i.tFirst,tl=i.tLast;" + \
    "if(typeof tf==='object'&&tf!==null)tf=Math.floor(tf.getTime()/1000);" + \
    "if(typeof tl==='object'&&tl!==null)tl=Math.floor(tl.getTime()/1000);" + \
    "print(JSON.stringify({" + \
    "logSizeBytes:Math.round((i.logSizeMB||0)*1048576)," + \
    "usedBytes:Math.round((i.usedMB||0)*1048576)," + \
    "tFirst:tf||0,tLast:tl||0," + \
    "now:Math.floor(new Date().getTime()/1000)" + \
    "}));}"

def _build_argv(params):
    binary = params.get("binary", "mongosh")
    host = params.get("host", "localhost")
    port = str(int(params.get("port", 27017)))
    username = params.get("username", "")
    password = params.get("password", "")
    auth_db = params.get("auth_db", "admin")
    argv = [binary, "--host", host, "--port", port, "--quiet", "--norc", "--eval", EVAL_SCRIPT]
    if username != "":
        argv = argv + ["--username", username, "--password", password, "--authenticationDatabase", auth_db]
    return argv

def _parse_json_line(raw):
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("{"):
            return json.decode(line)
    return None

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(_build_argv(params), mutates=False, ok_codes=[0, 1, 2, 127])
        if not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        data = _parse_json_line(res.stdout)
        if data == None or data.get("error") != None:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{
                "item": "",
                "params": {},
                "metrics": [
                    "mongodb_replication_info_log_size",
                    "mongodb_replication_info_used",
                    "mongodb_replication_info_time_diff",
                ],
            }]},
        }

    res = ctx.run(_build_argv(params), mutates=False, ok_codes=[0, 1])
    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no output from mongosh (rc=%d): %s" % (res.rc, res.stderr.strip()),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = _parse_json_line(res.stdout)
    if data == None:
        return {
            "changed": False,
            "msg": "could not parse mongosh output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if data.get("error") != None:
        return {
            "changed": False,
            "msg": "MongoDB replication info: " + str(data.get("error", "")),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    log_size = _int_or(data.get("logSizeBytes"), 0)
    used = _int_or(data.get("usedBytes"), 0)
    t_first = _int_or(data.get("tFirst"), 0)
    t_last = _int_or(data.get("tLast"), 0)
    time_diff = t_last - t_first
    if time_diff < 0:
        time_diff = 0

    oplog_summary = "Oplog size: %s of %s used" % (_format_bytes(used), _format_bytes(log_size))
    time_summary = "Time difference: %s between the first and last operation on oplog" % _format_timespan(time_diff)

    details = "\nOperations log (oplog):\n"
    details = details + "- Total amount of space allocated: %s\n" % _format_bytes(log_size)
    details = details + "- Total amount of space currently used: %s\n" % _format_bytes(used)
    details = details + "- Timestamp for the first operation: %d\n" % t_first
    details = details + "- Timestamp for the last operation: %d\n" % t_last
    details = details + "- Difference between the first and last operation: %s\n" % _format_timespan(time_diff)

    return {
        "changed": False,
        "msg": oplog_summary + ", " + time_summary,
        "data": {
            "state": "OK",
            "metrics": {
                "mongodb_replication_info_log_size": log_size,
                "mongodb_replication_info_used": used,
                "mongodb_replication_info_time_diff": time_diff,
            },
            "details": details,
        },
    }