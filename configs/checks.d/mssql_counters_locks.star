COUNTER_KEYS = [
    "lock_requests/sec",
    "lock_timeouts/sec",
    "number_of_deadlocks/sec",
    "lock_waits/sec",
]

COUNTER_TITLES = {
    "lock_requests/sec": "Requests",
    "lock_timeouts/sec": "Timeouts",
    "number_of_deadlocks/sec": "Deadlocks",
    "lock_waits/sec": "Waits",
}

_LOCKS_QUERY = (
    "SET NOCOUNT ON; " +
    "SELECT RTRIM(LTRIM(object_name)), RTRIM(LTRIM(counter_name)), " +
    "RTRIM(LTRIM(instance_name)), cntr_value " +
    "FROM sys.dm_os_performance_counters " +
    "WHERE object_name LIKE N'%:Locks%' " +
    "ORDER BY object_name, instance_name, counter_name"
)


def _sqlcmd(ctx, params):
    host = params.get("host", "localhost")
    port = str(params.get("port", 1433))
    user = params.get("user", "sa")
    password = params.get("password", "")
    instance = params.get("instance", "")
    if instance:
        server = "%s\\%s,%s" % (host, instance, port)
    else:
        server = "%s,%s" % (host, port)
    return ctx.run(
        ["sqlcmd", "-S", server, "-U", user, "-P", password,
         "-Q", _LOCKS_QUERY, "-h", "-1", "-W", "-s", "|"],
        mutates=False,
    )


def _parse(stdout):
    sections = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) < 4:
            continue
        obj = parts[0].strip().replace("$", "_")
        counter = parts[1].strip()
        inst = parts[2].strip()
        val_str = parts[3].strip()
        if not val_str.isdigit():
            continue
        norm = counter.lower().replace(" ", "_")
        item_key = obj + " " + inst
        if item_key not in sections:
            sections[item_key] = {}
        sections[item_key][norm] = int(val_str)
    return sections


def main(ctx, params):
    if params.get("_discover"):
        res = _sqlcmd(ctx, params)
        if res.rc != 0:
            return {"changed": False, "msg": "sqlcmd failed: " + res.stderr,
                    "data": {"discovery": []}}
        sections = _parse(res.stdout)
        out = []
        for item_key, counters in sections.items():
            if any([ck in counters for ck in COUNTER_KEYS]):
                out.append({
                    "item": item_key,
                    "params": {},
                    "metrics": [ck.replace("/sec", "_per_second")
                                for ck in COUNTER_KEYS if ck in counters],
                })
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")

    res1 = _sqlcmd(ctx, params)
    if res1.rc != 0:
        return {"changed": False, "msg": "sqlcmd failed: " + res1.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data1 = _parse(res1.stdout)
    if item not in data1:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ctx.run(["sleep", "1"], mutates=False)

    res2 = _sqlcmd(ctx, params)
    if res2.rc != 0:
        return {"changed": False, "msg": "second query failed: " + res2.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data2 = _parse(res2.stdout)
    if item not in data2:
        return {"changed": False, "msg": "item disappeared after interval: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    c1 = data1[item]
    c2 = data2[item]
    metrics = {}
    summary_parts = []
    overall = "OK"

    for ck in COUNTER_KEYS:
        if ck not in c1 or ck not in c2:
            continue
        rate = float(c2[ck] - c1[ck])
        if rate < 0.0:
            rate = 0.0
        metric_name = ck.replace("/sec", "_per_second")
        metrics[metric_name] = rate
        title = COUNTER_TITLES.get(ck, ck)
        levels = params.get(ck)
        state = "OK"
        if levels != None:
            warn = levels[0]
            crit = levels[1]
            if rate >= crit:
                state = "CRIT"
            elif rate >= warn:
                state = "WARN"
        if state == "CRIT":
            overall = "CRIT"
        elif state == "WARN" and overall == "OK":
            overall = "WARN"
        summary_parts.append("%s: %f/s" % (title, rate))

    if not summary_parts:
        return {"changed": False, "msg": "no lock counters found for: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": ", ".join(summary_parts),
            "data": {"state": overall, "metrics": metrics, "details": ""}}