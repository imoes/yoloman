def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            [
                "mongo",
                "--quiet",
                "--eval",
                "var o=db.oplog.rs.stats(); var ts=db.oplog.rs.find().sort({$natural:1}).limit(1).next().ts.t; var tl=db.oplog.rs.find().sort({$natural:-1}).limit(1).next().ts.t; printjson({tFirst:NumberLong(ts), tLast:NumberLong(tl), now:NumberLong(new Date().getTime()), usedBytes:NumberLong(o.size), logSizeBytes:NumberLong(o.maxSize)})",
            ],
            mutates=False,
        )
        if res.rc == 127 or not res.stdout:
            return {"changed": False, "msg": "mongo not found or no data",
                    "data": {"discovery": []}}
        section = None
        for line in res.stdout.splitlines():
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                section = json.decode(line)
                break
        if not section:
            return {"changed": False, "msg": "no oplog data", "data": {"discovery": []}}

        metrics = ["mongodb_replication_info_log_size",
                   "mongodb_replication_info_used",
                   "mongodb_replication_info_time_diff"]
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": metrics}
                ]}}

    item = params.get("item", "")
    res = ctx.run(
        [
            "mongo",
            "--quiet",
            "--eval",
            "var o=db.oplog.rs.stats(); var ts=db.oplog.rs.find().sort({$natural:1}).limit(1).next().ts.t; var tl=db.oplog.rs.find().sort({$natural:-1}).limit(1).next().ts.t; printjson({tFirst:NumberLong(ts), tLast:NumberLong(tl), now:NumberLong(new Date().getTime()), usedBytes:NumberLong(o.size), logSizeBytes:NumberLong(o.maxSize)})",
        ],
        mutates=False,
    )
    if res.rc == 127:
        return {"changed": False, "msg": "mongo shell not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "mongo query failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            section = json.decode(line)
            break
    if not section:
        return {"changed": False, "msg": "no replication info data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def _as_int(d, key):
        v = d.get(key)
        if v == None:
            return 0
        if type(v) == "int":
            return v
        if type(v) == "string":
            return int(v) if v.lstrip("-").isdigit() else 0
        return 0

    def _bytes_human_readable(d, key):
        v = _as_int(d, key)
        if v < 1024:
            return str(v) + " B"
        units = ["B", "KB", "MB", "GB", "TB", "PB"]
        u = 0
        val = float(v)
        while val >= 1024 and u < len(units) - 1:
            val = val / 1024.0
            u = u + 1
        return "%f %s" % (val, units[u])

    def _timestamp_human_readable(d, key):
        v = _as_int(d, key)
        return str(v)

    def _timespan_human(seconds):
        if seconds < 60:
            return str(seconds) + " s"
        if seconds < 3600:
            return "%d min" % (seconds / 60)
        if seconds < 86400:
            return "%d h" % (seconds / 3600)
        return "%d d" % (seconds / 86400)

    def _calc_time_diff(v1, v2):
        if v1 == None or v2 == None:
            return "n/a"
        return _timespan_human(v1 - v2)

    log_size = _bytes_human_readable(section, "logSizeBytes")
    used = _bytes_human_readable(section, "usedBytes")
    oplog_size = "Oplog size: " + used + " of " + log_size + " used"

    t_first = _as_int(section, "tFirst")
    t_last = _as_int(section, "tLast")
    time_difference_sec = t_last - t_first
    time_diff = "Time difference: " + _timespan_human(time_difference_sec) + \
        " between the first and last operation on oplog"

    ts_first = _timestamp_human_readable(section, "tFirst")
    ts_last = _timestamp_human_readable(section, "tLast")
    ts_now = _timestamp_human_readable(section, "now")
    td_str = _calc_time_diff(t_last, t_first)

    long_output = []
    long_output.append("Operations log (oplog):")
    long_output.append("- Total amount of space allocated: " + log_size)
    long_output.append("- Total amount of space currently used: " + used)
    long_output.append("- Timestamp for the first operation: " + ts_first)
    long_output.append("- Timestamp for the last operation: " + ts_last)
    long_output.append("- Difference between the first and last operation: " + td_str)
    long_output.append("")
    long_output.append("- Current time on host: " + ts_now)
    details = "\n" + "\n".join(long_output)

    metrics = {
        "mongodb_replication_info_log_size": _as_int(section, "logSizeBytes"),
        "mongodb_replication_info_used": _as_int(section, "usedBytes"),
        "mongodb_replication_info_time_diff": time_difference_sec,
    }

    msg = oplog_size + ", " + time_diff
    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": metrics, "details": details}}