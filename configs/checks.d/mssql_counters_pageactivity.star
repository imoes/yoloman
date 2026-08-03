# MSSQL Page Activity check — translated from Checkmk's mssql_counters_pageactivity
# Monitors page reads/writes/lookups per second from SQL Server's Buffer Manager counters.
# Data source: real SQL Server via sqlcmd querying sys.dm_os_performance_counters.

def _parse_sqlcmd_out(lines):
    rows = []
    header = None
    for raw in lines:
        line = raw.strip()
        if line == "":
            continue
        parts = line.split("|")
        if header == None:
            header = [p.strip() for p in parts]
            continue
        row = {}
        for i in range(len(parts)):
            key = header[i] if i < len(header) else "col%d" % i
            row[key] = parts[i].strip()
        rows.append(row)
    return rows

def _parse_value(value_str):
    if value_str == None or value_str == "":
        return 0
    cleaned = value_str.strip().replace(",", "")
    if cleaned.lstrip("-").isdigit():
        return int(cleaned)
    negative = False
    test = cleaned
    if test.startswith("-"):
        negative = True
        test = test[1:]
    if "." in test:
        dot_parts = test.split(".")
        if len(dot_parts) == 2 and dot_parts[0].isdigit() and dot_parts[1].isdigit():
            return float(cleaned)
    return 0

def _group_counters(rows):
    grouped = {}
    if not rows:
        return grouped
    for row in rows:
        obj = row.get("object_name", "")
        counter = row.get("counter_name", "")
        instance = row.get("instance_name", "None")
        value = _parse_value(row.get("cntr_value", "0"))
        key = (obj, instance)
        if key not in grouped:
            grouped[key] = {}
        grouped[key][counter] = value
    return grouped

def _levels_tuple(level_key):
    warn_val = None
    crit_val = None
    if level_key == None:
        return (None, None)
    if type(level_key) == "list":
        if len(level_key) >= 1:
            warn_val = float(level_key[0])
        if len(level_key) >= 2:
            crit_val = float(level_key[1])
    elif type(level_key) == "dict":
        if "warn" in level_key:
            warn_val = float(level_key["warn"])
        if "crit" in level_key:
            crit_val = float(level_key["crit"])
    return (warn_val, crit_val)

def _run_sql_query(ctx, sql_instance):
    query = (
        "SELECT object_name, counter_name, instance_name, cntr_value " +
        "FROM sys.dm_os_performance_counters " +
        "WHERE object_name LIKE " + "'" + "%Buffer Manager%" + "' " +
        "AND counter_name IN (" +
        "'page reads/sec'," + "'page writes/sec'," + "'page lookups/sec'," + "'readahead pages/sec')"
    )
    args = ["sqlcmd", "-S", sql_instance, "-E", "-s|", "-W", "-Q", query]
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        return None
    return _parse_sqlcmd_out(res.stdout.splitlines())

def main(ctx, params):
    sql_instance = params.get("sql_instance", "localhost")

    if params.get("_discover"):
        rows = _run_sql_query(ctx, sql_instance)
        if rows == None or len(rows) == 0:
            return {"changed": False, "msg": "no mssql instance found",
                    "data": {"discovery": []}}
        grouped = _group_counters(rows)
        discovery = []
        metric_map = {
            "page reads/sec": "page_reads_per_second",
            "page writes/sec": "page_writes_per_second",
            "page lookups/sec": "page_lookups_per_second",
        }
        for key in sorted(grouped.keys()):
            obj_name = key[0]
            inst_name = key[1]
            counters = grouped[key]
            has_required = False
            for c in ("page reads/sec", "page writes/sec", "page lookups/sec"):
                if c in counters:
                    has_required = True
                    break
            if not has_required:
                continue
            item_name = obj_name + " " + inst_name
            metrics = []
            for c in ("page reads/sec", "page writes/sec", "page lookups/sec"):
                if c in counters:
                    metrics.append(metric_map[c])
            discovery.append({
                "item": item_name,
                "params": {},
                "metrics": metrics,
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False,
                "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = _run_sql_query(ctx, sql_instance)
    if rows == None or len(rows) == 0:
        return {"changed": False,
                "msg": "no mssql instance found for item",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    grouped = _group_counters(rows)
    target_counters = None
    for key in grouped:
        obj_name = key[0]
        inst_name = key[1]
        candidate = obj_name + " " + inst_name
        if candidate == item:
            target_counters = grouped[key]
            break

    if target_counters == None:
        return {"changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metric_map = {
        "page reads/sec": "page_reads_per_second",
        "page writes/sec": "page_writes_per_second",
        "page lookups/sec": "page_lookups_per_second",
    }
    label_map = {
        "page reads/sec": "Reads",
        "page writes/sec": "Writes",
        "page lookups/sec": "Lookups",
    }
    metrics = {}
    state = "OK"
    details_parts = []
    for counter_name in ("page reads/sec", "page writes/sec", "page lookups/sec"):
        if counter_name in target_counters:
            value = float(target_counters[counter_name])
            metric_name = metric_map[counter_name]
            metrics[metric_name] = value
            level_key = params.get(counter_name)
            warn_val, crit_val = _levels_tuple(level_key)
            if crit_val != None and value >= crit_val:
                state = "CRIT"
            elif warn_val != None and value >= warn_val:
                if state != "CRIT":
                    state = "WARN"
            label = label_map[counter_name]
            details_parts.append("%s: %f" % (label, value))

    msg = ", ".join(details_parts) if details_parts else "page activity counters"
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": msg,
        },
    }