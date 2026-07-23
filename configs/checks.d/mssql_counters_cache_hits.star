WANT_COUNTERS = ["cache_hit_ratio", "log_cache_hit_ratio", "buffer_cache_hit_ratio"]

def _normalize_obj(raw):
    colon = raw.find(":")
    if colon < 0:
        return raw.replace(" ", "_")
    pre = raw[:colon]
    post = raw[colon + 1:]
    if pre == "SQLServer":
        pre = "MSSQL_MSSQLSERVER"
    elif pre.startswith("MSSQL$"):
        pre = "MSSQL_" + pre[6:]
    return pre + ":" + post.replace(" ", "_")

def _server_str(params):
    host = params.get("host", "localhost")
    instance = params.get("instance", "")
    port = str(params.get("port", 1433))
    if instance != "":
        return host + "\\" + instance
    return host + "," + port

def _query(ctx, params):
    sql = (
        "SET NOCOUNT ON; SELECT RTRIM(object_name), " +
        "LOWER(REPLACE(RTRIM(counter_name), ' ', '_')), " +
        "CASE WHEN RTRIM(instance_name) = '' THEN 'None' ELSE RTRIM(instance_name) END, " +
        "cntr_value FROM sys.dm_os_performance_counters " +
        "WHERE LOWER(REPLACE(RTRIM(counter_name), ' ', '_')) IN (" +
        "'cache_hit_ratio','log_cache_hit_ratio','buffer_cache_hit_ratio'," +
        "'cache_hit_ratio_base','log_cache_hit_ratio_base','buffer_cache_hit_ratio_base');"
    )
    user = params.get("user", "")
    password = params.get("password", "")
    argv = ["sqlcmd", "-S", _server_str(params), "-Q", sql, "-s", "|", "-W", "-h", "-1"]
    if user != "":
        argv = argv + ["-U", user, "-P", password]
    return ctx.run(argv, mutates=False)

def _parse(stdout):
    section = {}
    for line in stdout.splitlines():
        line = line.strip()
        if line == "" or line.startswith("-"):
            continue
        parts = line.split("|")
        if len(parts) < 4:
            continue
        obj = _normalize_obj(parts[0].strip())
        counter = parts[1].strip()
        inst = parts[2].strip()
        val_s = parts[3].strip()
        if not val_s.lstrip("-").isdigit():
            continue
        key = obj + " " + inst
        if key not in section:
            section[key] = {}
        section[key][counter] = int(val_s)
    return section

def main(ctx, params):
    if params.get("_discover"):
        res = _query(ctx, params)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "sqlcmd failed: " + res.stderr,
                "data": {"discovery": []},
            }
        section = _parse(res.stdout)
        add_zero = params.get("add_zero_based_services", False)
        items = []
        for key, counters in section.items():
            for counter in WANT_COUNTERS:
                if counter not in counters:
                    continue
                base = counters.get(counter + "_base", 0)
                if base == 0 and not add_zero:
                    continue
                items.append({
                    "item": key + " " + counter,
                    "params": {},
                    "metrics": [counter],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    last = item.rfind(" ")
    if last < 0:
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    counter = item[last + 1:]
    key = item[:last]

    res = _query(ctx, params)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "sqlcmd failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _parse(res.stdout)
    counters = section.get(key)
    if counters == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = counters.get(counter)
    if value == None:
        return {
            "changed": False,
            "msg": "counter not found: " + counter,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    base = counters.get(counter + "_base", 0)
    pct = (100.0 * value / base) if base != 0 else 0.0

    warn = params.get("warn", None)
    crit = params.get("crit", None)

    state = "OK"
    if (crit != None) and (pct <= float(crit)):
        state = "CRIT"
    elif (warn != None) and (pct <= float(warn)):
        state = "WARN"

    return {
        "changed": False,
        "msg": "%s %f%%" % (counter, pct),
        "data": {
            "state": state,
            "metrics": {counter: pct},
            "details": "",
        },
    }