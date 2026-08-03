# Checkmk check: redis_info_persistence
# Translated to read-only Starlark module for yolo-man agent.
# Monitors Redis persistence (RDB/AOF) state per instance.

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["redis-cli", "--version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "redis-cli not installed",
                    "data": {"discovery": [], "host_labels": {}}}
        if probe.rc != 0:
            return {"changed": False, "msg": "redis-cli probe failed",
                    "data": {"discovery": []}}

        host = params.get("host", "localhost")
        port = params.get("port", "6379")

        instances = _get_instances(ctx, params)
        discovery = []
        for inst in instances:
            persistence_data = _fetch_persistence(ctx, inst)
            if persistence_data != None:
                metrics = _discover_metrics(persistence_data)
                labels = {}
                inst_parts = inst.split("|") if "|" in inst else [host, str(port)]
                if len(inst_parts) >= 2:
                    labels["redis/host"] = inst_parts[0]
                    labels["redis/port"] = inst_parts[1]
                discovery.append({
                    "item": inst,
                    "params": {
                        "rdb_last_bgsave_state": params.get("rdb_last_bgsave_state", 1),
                        "aof_last_rewrite_state": params.get("aof_last_rewrite_state", 1),
                        "rdb_changes_count": params.get("rdb_changes_count", None),
                    },
                    "metrics": metrics,
                    "service_labels": labels,
                })
        host_labels = {"cmk/os_family": _detect_os_family(ctx)}
        return {"changed": False,
                "msg": "discovered %d redis persistence instances" % len(discovery),
                "data": {"discovery": discovery, "host_labels": host_labels}}

    item = params.get("item", "")
    persistence_data = _fetch_persistence(ctx, item)
    if persistence_data == None:
        return {"changed": False,
                "msg": "no persistence data for redis instance %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    results = []
    metrics = {}
    details_parts = []

    for status, duration, infotext in [
        ("rdb_last_bgsave_status", "rdb_last_bgsave", "Last RDB save operation: "),
        ("aof_last_bgrewrite_status", "aof_last_rewrite", "Last AOF rewrite operation: "),
    ]:
        value = persistence_data.get(status)
        if value != None:
            state = "OK"
            if value != "ok":
                state_key = "%s_state" % duration
                state_val = params.get(state_key, 1)
                state = _state_from_int(state_val)
                infotext = infotext + "faulty"
            else:
                infotext = infotext + "successful"

            duration_val = persistence_data.get("%s_time_sec" % duration)
            if duration_val != None and duration_val != -1:
                infotext = infotext + " (Duration: %s)" % _render_timespan(int(duration_val))
            results.append({"state": state, "summary": infotext})
            details_parts.append(infotext)

    rdb_save_time = persistence_data.get("rdb_last_save_time")
    if rdb_save_time != None:
        results.append({
            "state": "OK",
            "summary": "Last successful RDB save: %s" % _render_datetime(int(rdb_save_time)),
        })
        details_parts.append("Last RDB save: %s" % _render_datetime(int(rdb_save_time)))

    rdb_changes = persistence_data.get("rdb_changes_since_last_save")
    if rdb_changes != None:
        changes = int(rdb_changes)
        metrics["changes_sld"] = changes
        levels = params.get("rdb_changes_count")
        if levels != None:
            warn_level = None
            crit_level = None
            if type(levels) == "list" and len(levels) >= 2:
                warn_level = levels[0]
                crit_level = levels[1]
            elif type(levels) == "dict":
                warn_level = levels.get("warn")
                crit_level = levels.get("crit")
            state = "OK"
            if crit_level != None and changes >= crit_level:
                state = "CRIT"
            elif warn_level != None and changes >= warn_level:
                state = "WARN"
            results.append({
                "state": state,
                "summary": "Number of changes since last dump: %d" % changes,
            })
            details_parts.append("Changes since last dump: %d" % changes)

    if len(results) == 0:
        return {"changed": False, "msg": "no persistence data to report",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    overall_state = _worst_state(results)
    summaries = []
    for d in results:
        summaries.append(d["summary"])
    summary = summaries[0] if len(summaries) == 1 else "; ".join(summaries)
    details = "\n".join(details_parts)
    return {"changed": False, "msg": summary,
            "data": {"state": overall_state, "metrics": metrics, "details": details}}


# ---- helpers ----

def _state_from_int(v):
    # Checkmk State: 0=OK, 1=WARN, 2=CRIT
    if v == 0:
        return "OK"
    if v == 1:
        return "WARN"
    if v == 2:
        return "CRIT"
    return "WARN"

def _worst_state(results):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    for r in results:
        s = r.get("state", "OK")
        if rank.get(s, 0) > rank.get(worst, 0):
            worst = s
    return worst

def _get_instances(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", "6379")
    inst_key = host + "|" + str(port)
    return [inst_key]

def _fetch_persistence(ctx, item):
    parts = item.split("|")
    if len(parts) < 2:
        return None
    host = parts[0]
    port = parts[1]
    return _redis_info_persistence(ctx, host, port)

def _redis_info_persistence(ctx, host, port):
    res = ctx.run(["redis-cli", "-h", host, "-p", str(port), "INFO", "persistence"], mutates=False)
    if res.rc != 0 or res.skipped:
        return None
    lines = res.stdout.split("\n")
    if len(lines) == 0:
        return None
    data = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("$"):
            continue
        kv = line.split(":", 1)
        if len(kv) != 2:
            continue
        key = kv[0]
        raw_val = kv[1]
        val = _coerce_int(raw_val)
        if val == None:
            val = _coerce_float(raw_val)
        if val == None:
            val = raw_val
        data[key] = val
    return data

def _coerce_int(s):
    if s == None:
        return None
    t = s.strip()
    neg = False
    body = t
    if t.startswith("-"):
        neg = True
        body = t[1:]
    if len(body) > 0 and body.isdigit():
        v = int(body)
        return v if (not neg) else -v
    return None

def _coerce_float(s):
    if s == None:
        return None
    t = s.strip()
    neg = False
    body = t
    if t.startswith("-"):
        neg = True
        body = t[1:]
    dot_count = body.count(".")
    if dot_count == 1:
        int_part, _, frac_part = body.partition(".")
        int_ok = (len(int_part) > 0 and int_part.isdigit()) or (int_part == "")
        frac_ok = (len(frac_part) > 0 and frac_part.isdigit()) or (frac_part == "")
        if int_ok and frac_ok:
            if int_part == "" and frac_part == "":
                return None
            val = float(t)
            return val if (not neg) else -val
    return None

def _discover_metrics(persistence_data):
    metrics = []
    if persistence_data.get("rdb_changes_since_last_save") != None:
        metrics.append("changes_sld")
    return metrics

def _detect_os_family(ctx):
    f = ctx.facts()
    return f.get("os_family", "linux")

def _render_timespan(seconds):
    if seconds < 0:
        return "%ds" % seconds
    if seconds == 0:
        return "0s"
    parts = []
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    if days > 0:
        parts.append("%dd" % days)
    if hours > 0:
        parts.append("%dh" % hours)
    if minutes > 0:
        parts.append("%dm" % minutes)
    parts.append("%ds" % secs)
    return " ".join(parts)

def _render_datetime(epoch):
    days_total = epoch // 86400
    secs_in_day = epoch % 86400
    hour = secs_in_day // 3600
    minute = (secs_in_day % 3600) // 60
    second = secs_in_day % 60
    y = 1970
    remaining = days_total
    while True:
        leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)
        year_days = 366 if leap else 365
        if remaining < year_days:
            break
        remaining = remaining - year_days
        y = y + 1
    month_days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0):
        month_days[1] = 29
    mo = 0
    while mo < 12 and remaining >= month_days[mo]:
        remaining = remaining - month_days[mo]
        mo = mo + 1
    month = mo + 1
    day = remaining + 1
    return "%d-%d-%d %d:%d:%d" % (y, month, day, hour, minute, second)