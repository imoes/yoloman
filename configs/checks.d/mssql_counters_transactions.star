COUNTER_SQL_NAMES = "('Transactions/sec', 'Write Transactions/sec', 'Tracked transactions/sec')"

COUNTER_TITLES = {
    "transactions/sec": "Transactions",
    "write_transactions/sec": "Write Transactions",
    "tracked_transactions/sec": "Tracked Transactions",
}

METRIC_NAMES = {
    "transactions/sec": "transactions_per_second",
    "write_transactions/sec": "write_transactions_per_second",
    "tracked_transactions/sec": "tracked_transactions_per_second",
}

COUNTER_ORDER = ["transactions/sec", "write_transactions/sec", "tracked_transactions/sec"]


def _norm_obj(raw):
    s = raw.strip()
    dollar = s.find("$")
    if dollar >= 0:
        s = "MSSQL_" + s[dollar + 1:]
    colon = s.find(":")
    if colon >= 0:
        s = s[:colon]
    return s


def _norm_counter(raw):
    return raw.strip().lower().replace(" ", "_")


def _sqlcmd(ctx):
    for p in ["/opt/mssql-tools18/bin/sqlcmd", "/opt/mssql-tools/bin/sqlcmd"]:
        if ctx.file_exists(p):
            return p
    return "sqlcmd"


def _server(params):
    host = params.get("host", "localhost")
    port = params.get("port", 1433)
    if int(port) != 1433:
        return "%s,%d" % (host, int(port))
    return host


def _run(ctx, params, sql):
    return ctx.run(
        [
            _sqlcmd(ctx),
            "-S", _server(params),
            "-U", params.get("username", "sa"),
            "-P", params.get("password", ""),
            "-d", "master",
            "-Q", sql,
            "-s", "\t",
            "-W",
            "-h", "-1",
        ],
        mutates=False,
    )


def _parse_int(s):
    s = s.strip()
    if s.startswith("-"):
        rest = s[1:]
        if rest.isdigit():
            return int(s)
        return None
    if s.isdigit():
        return int(s)
    return None


def main(ctx, params):
    if params.get("_discover"):
        sql = (
            "SET NOCOUNT ON;" +
            "SELECT RTRIM(object_name), RTRIM(instance_name), RTRIM(counter_name)" +
            " FROM sys.dm_os_performance_counters" +
            " WHERE object_name LIKE '%:Databases%'" +
            " AND RTRIM(counter_name) IN " + COUNTER_SQL_NAMES +
            " AND RTRIM(instance_name) NOT IN ('', '_Total')" +
            " ORDER BY object_name, instance_name;"
        )
        res = _run(ctx, params, sql)
        if res.rc != 0:
            return {"changed": False, "msg": "sqlcmd failed: " + res.stderr,
                    "data": {"discovery": []}}

        items = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split("\t")
            if len(parts) < 3:
                continue
            obj_raw = parts[0].strip()
            db = parts[1].strip()
            ctr_raw = parts[2].strip()
            if not obj_raw or not db or not ctr_raw:
                continue
            inst = _norm_obj(obj_raw)
            item = inst + " " + db
            ctr = _norm_counter(ctr_raw)
            if item not in items:
                items[item] = []
            if ctr not in items[item]:
                items[item].append(ctr)

        disc = []
        for item in sorted(items.keys()):
            ctrs = items[item]
            metrics = [METRIC_NAMES[c] for c in COUNTER_ORDER if c in ctrs]
            disc.append({"item": item, "params": {}, "metrics": metrics})

        return {"changed": False, "msg": "discovered %d items" % len(disc),
                "data": {"discovery": disc}}

    item = params.get("item", "")
    item_parts = item.split(" ", 1)
    if len(item_parts) < 2:
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    db = item_parts[1].replace("'", "''")

    sql = (
        "SET NOCOUNT ON;" +
        "DECLARE @r TABLE(cname nvarchar(200), v1 bigint, v2 bigint);" +
        "INSERT @r(cname, v1)" +
        " SELECT RTRIM(counter_name), cntr_value" +
        " FROM sys.dm_os_performance_counters" +
        " WHERE object_name LIKE '%:Databases%'" +
        " AND RTRIM(counter_name) IN " + COUNTER_SQL_NAMES +
        " AND RTRIM(instance_name) = '" + db + "';" +
        "WAITFOR DELAY '00:00:01';" +
        "UPDATE r SET r.v2 = p.cntr_value" +
        " FROM @r r" +
        " JOIN sys.dm_os_performance_counters p" +
        " ON RTRIM(p.counter_name) = RTRIM(r.cname)" +
        " AND p.object_name LIKE '%:Databases%'" +
        " AND RTRIM(p.instance_name) = '" + db + "';" +
        "SELECT RTRIM(cname), (v2 - v1) FROM @r ORDER BY cname;"
    )

    res = _run(ctx, params, sql)
    if res.rc != 0:
        return {"changed": False, "msg": "sqlcmd failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not res.stdout.strip():
        return {"changed": False, "msg": "no data for: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rates = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split("\t")
        if len(parts) < 2:
            continue
        cname = parts[0].strip()
        val = _parse_int(parts[1])
        if val == None:
            continue
        ckey = _norm_counter(cname)
        rates[ckey] = val if val >= 0 else 0

    if not rates:
        return {"changed": False, "msg": "no counter data for: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    summaries = []
    state = "OK"

    for ckey in COUNTER_ORDER:
        if ckey not in rates:
            continue
        rate = float(rates[ckey])
        mname = METRIC_NAMES[ckey]
        metrics[mname] = rate
        title = COUNTER_TITLES[ckey]
        item_state = "OK"
        levels = params.get(ckey)
        if levels != None:
            warn = float(levels[0])
            crit = float(levels[1])
            if rate >= crit:
                item_state = "CRIT"
            elif rate >= warn:
                item_state = "WARN"
        summaries.append("%s: %f/s" % (title, rate))
        if item_state == "CRIT":
            state = "CRIT"
        elif item_state == "WARN" and state == "OK":
            state = "WARN"

    msg = ", ".join(summaries) if summaries else "no metrics"
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}