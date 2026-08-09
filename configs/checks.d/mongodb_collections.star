def main(ctx, params):
    if params.get("_discover"):
        if not _mongodb_available(ctx, params):
            return {"changed": False, "msg": "mongodb not available",
                    "data": {"discovery": []}}
        db_names = ctx.run(["mongo", "--quiet", "--eval", "db.adminCommand('listDatabases').databases.forEach(d=>print(d.name))"],
                           mutates=False)
        if db_names.rc != 0 or not db_names.stdout:
            return {"changed": False, "msg": "no databases", "data": {"discovery": []}}
        out = []
        for db in db_names.stdout.splitlines():
            db = db.strip()
            if not db:
                continue
            colls = ctx.run(["mongo", "--quiet", db, "--eval",
                             "db.getCollectionNames().forEach(print)"], mutates=False)
            if colls.rc != 0:
                continue
            for coll in colls.stdout.splitlines():
                coll = coll.strip()
                if not coll:
                    continue
                out.append({"item": db + "." + coll, "params": {}, "metrics": [
                    "mongodb_collection_size", "mongodb_collection_storage_size",
                    "mongodb_collection_total_index_size", "mongodb_collection_nindexes"]})
        return {"changed": False, "msg": "discovered %d collections" % len(out),
                "data": {"discovery": out}}
    if not _mongodb_available(ctx, params):
        return {"changed": False, "msg": "mongodb not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    item = params.get("item", "")
    database_name, collection_name = _split_namespace(item)
    if database_name == "" or collection_name == "":
        return {"changed": False, "msg": "invalid namespace: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    stats = _coll_stats(ctx, params, database_name, collection_name)
    if stats == None:
        return {"changed": False, "msg": "collection not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    metrics = {}
    details_parts = ["Collection"]
    if stats.get("sharded", None):
        details_parts.append("- Sharded: %s" % stats["sharded"])
        details_parts.append("- Shards: %s" % _get_as_int(stats, "shardsCount"))
        details_parts.append("- Chunks: %s" % _get_as_int(stats, "nchunks"))
    details_parts.append("- Document Count: %s" % _get_as_int(stats, "count"))
    details_parts.append("- Average object size: %s" % _bytes(stats, "avgObjSize"))
    details_parts.append("- Collection size: %s" % _bytes(stats, "size"))
    details_parts.append("- Storage size: %s" % _bytes(stats, "storageSize"))
    details_parts.append("")
    details_parts.append("Indexes:")
    details_parts.append("- Total index size: %s" % _bytes(stats, "totalIndexSize"))
    details_parts.append("- Number of indexes: %s" % _get_as_int(stats, "nindexes"))
    for index in _get_indexes_as_list(stats):
        details_parts.append("-- Index '%s' used %s times since %s" %
                             (index[0], index[1], _timestamp_human_readable(index[2])))
    details = "\n".join(details_parts)
    state = "OK"
    for key, levels_key, factor in (("size", "levels_size", 1024 * 1024),
                                    ("storageSize", "levels_storageSize", 1024 * 1024),
                                    ("totalIndexSize", "levels_totalIndexSize", 1024)):
        if key not in stats:
            continue
        value = _safe_int(stats.get(key))
        if value == None:
            continue
        levels = params.get(levels_key)
        if levels:
            levels = (levels[0] * factor, levels[1] * factor)
        metric_name = _get_perfdata_key(key)
        if metric_name:
            metrics[metric_name] = value
        if levels:
            if value >= levels[1]:
                state = "CRIT"
            elif value >= levels[0]:
                if state != "CRIT":
                    state = "WARN"
    nindexes = _safe_int(stats.get("nindexes"))
    if nindexes != None:
        metrics["mongodb_collection_nindexes"] = nindexes
        if nindexes >= 65:
            state = "CRIT"
        elif nindexes >= 62:
            if state != "CRIT":
                state = "WARN"
    label = "size=%s" % _bytes(stats, "size") if "size" in stats else ""
    msg = "Collection %s" % item
    if label:
        msg = msg + ", " + label
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}


def _mongodb_available(ctx, params):
    res = ctx.run(["mongo", "--version"], mutates=False)
    return res.rc == 0


def _coll_stats(ctx, params, db_name, coll_name):
    eval = "db.getSiblingDB('%s').getCollection('%s').aggregate([{'$collStats':{size:1, storageSize:1, totalIndexSize:1, avgObjSize:1, count:1, nindexes:1, sharded:1, shardsCount:1, nchunks:1}}]).forEach(printjson)" % (db_name, coll_name)
    res = ctx.run(["mongo", "--quiet", "--eval", eval], mutates=False)
    if res.rc != 0:
        return None
    raw = res.stdout.strip()
    if not raw:
        return None
    fixed = raw.replace("'", '"')
    d = json.decode(fixed)
    if type(d) == "list" and len(d) > 0 and type(d[0]) == "dict":
        return d[0]
    return d


def _split_namespace(namespace):
    names = namespace.split(".", 1)
    if len(names) > 1:
        return names[0], names[1]
    if len(names) > 0:
        return names[0], ""
    return "", ""


def _get_perfdata_key(key):
    if key == "size":
        return "mongodb_collection_size"
    if key == "storageSize":
        return "mongodb_collection_storage_size"
    if key == "totalIndexSize":
        return "mongodb_collection_total_index_size"
    return None


def _get_as_int(data, key):
    v = data.get(key)
    if v == None:
        return "n/a"
    return _safe_int(v)


def _bytes(data, key):
    v = data.get(key)
    if v == None:
        return "n/a"
    n = _safe_int(v)
    if n == None:
        return "n/a"
    return _human_readable(n)


def _safe_int(v):
    if type(v) == "int":
        return v
    if type(v) == "float":
        return int(v)
    if type(v) == "string":
        if v.isdigit():
            return int(v)
        neg = v.startswith("-")
        body = v[1:] if neg else v
        if body.isdigit():
            return int(v)
    return None


def _human_readable(n):
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    i = 0
    while n >= 1024 and i < len(units) - 1:
        n = n // 1024
        i = i + 1
    return "%d%s" % (n, units[i])


def _get_indexes_as_list(data):
    if "indexStats" not in data:
        return []
    index_list = []
    for index_stat in data["indexStats"]:
        index_name = index_stat.get("name", "n/a")
        accesses = index_stat.get("accesses", {})
        since = accesses.get("since", {})
        since_date = since.get("$date", 0) if type(since) == "dict" else 0
        last_access = _parse_date(since_date)
        ops = accesses.get("ops", 0)
        index_list.append((index_name, ops, last_access))
    index_list = sorted(index_list, key=_sort_second, reverse=True)
    return index_list


def _sort_second(tup):
    return tup[1]


def _parse_date(date):
    if type(date) == "string":
        return _iso_to_epoch(date)
    return float(date) / 1000.0


def _iso_to_epoch(s):
    datepart, timepart = s.split("T", 1)
    year, month, day = datepart.split("-")
    timepart = timepart.split("Z")[0]
    hh, mm, ss = timepart.split(":")
    sec_parts = ss.split(".")
    ms = 0.0
    if len(sec_parts) > 1:
        ms = float("0." + sec_parts[1])
    return int(year)*31536000 + int(month)*2592000 + int(day)*86400 + int(hh)*3600 + int(mm)*60 + int(sec_parts[0]) + ms


def _timestamp_human_readable(value):
    return str(int(value))