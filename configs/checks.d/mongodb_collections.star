def _fmt_bytes(b):
    b = int(b)
    gib = 1024 * 1024 * 1024
    mib = 1024 * 1024
    kib = 1024
    if b >= gib:
        return "%f GiB" % (b / gib)
    if b >= mib:
        return "%f MiB" % (b / mib)
    if b >= kib:
        return "%f KiB" % (b / kib)
    return "%d B" % b

def _split_item(item):
    parts = item.split(".", 1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return parts[0], ""

def _worst_state(s1, s2):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if rank.get(s1, 0) >= rank.get(s2, 0):
        return s1
    return s2

def _threshold_state(value, warn, crit):
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def _extract_json(text):
    last = ""
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("{"):
            last = s
    return last

def _build_cmd(params, eval_js):
    host = params.get("host", "localhost")
    port = str(params.get("port", 27017))
    username = params.get("username", "")
    password = params.get("password", "")
    authdb = params.get("authdb", "admin")
    cmd = ["mongosh", "--host", host, "--port", port, "--quiet", "--eval", eval_js]
    if username != "":
        cmd = cmd + ["--username", username, "--password", password,
                     "--authenticationDatabase", authdb]
    return cmd

_DISCOVER_JS = """var r={};try{db.adminCommand({listDatabases:1}).databases.forEach(function(d){try{var c=db.getSiblingDB(d.name);var cs={};c.getCollectionNames().forEach(function(n){try{var s=c.runCommand({collStats:n});if(s.ok)cs[n]=s;}catch(e){}});r[d.name]={collstats:cs};}catch(e){}});}catch(e){}print(JSON.stringify(r));"""

def main(ctx, params):
    if params.get("_discover"):
        cmd = _build_cmd(params, _DISCOVER_JS)
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "mongosh failed: " + res.stderr.strip(),
                "data": {"discovery": []},
            }
        raw = _extract_json(res.stdout)
        if not raw:
            return {"changed": False, "msg": "no JSON output from mongosh", "data": {"discovery": []}}
        data = json.decode(raw)
        items = []
        for db_name in data:
            collstats = data.get(db_name, {}).get("collstats", {})
            for coll_name in collstats:
                items.append({
                    "item": db_name + "." + coll_name,
                    "params": {},
                    "metrics": [
                        "mongodb_collection_size",
                        "mongodb_collection_storage_size",
                        "mongodb_collection_total_index_size",
                    ],
                })
        return {
            "changed": False,
            "msg": "discovered %d collections" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    db_name, coll_name = _split_item(item)
    if coll_name == "":
        return {
            "changed": False,
            "msg": "invalid item (expected db.collection): " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    check_js = (
        "var s=db.getSiblingDB('%s').runCommand({collStats:'%s'});" % (db_name, coll_name) +
        "print(JSON.stringify(s));"
    )
    cmd = _build_cmd(params, check_js)
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "mongosh failed: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    raw = _extract_json(res.stdout)
    if not raw:
        return {
            "changed": False,
            "msg": "no data for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    stats = json.decode(raw)
    ok_val = stats.get("ok")
    if ok_val == None or int(ok_val) != 1:
        errmsg = stats.get("errmsg", "unknown error")
        return {
            "changed": False,
            "msg": "collection error: " + str(errmsg),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    msg_parts = []
    overall = "OK"

    size_raw = stats.get("size")
    if size_raw != None:
        size = int(size_raw)
        levels_s = params.get("levels_size")
        warn_s = levels_s[0] * 1024 * 1024 if levels_s != None else None
        crit_s = levels_s[1] * 1024 * 1024 if levels_s != None else None
        overall = _worst_state(overall, _threshold_state(size, warn_s, crit_s))
        metrics["mongodb_collection_size"] = size
        msg_parts.append("Size: " + _fmt_bytes(size))

    stor_raw = stats.get("storageSize")
    if stor_raw != None:
        stor = int(stor_raw)
        levels_st = params.get("levels_storageSize")
        warn_st = levels_st[0] * 1024 * 1024 if levels_st != None else None
        crit_st = levels_st[1] * 1024 * 1024 if levels_st != None else None
        overall = _worst_state(overall, _threshold_state(stor, warn_st, crit_st))
        metrics["mongodb_collection_storage_size"] = stor
        msg_parts.append("Storage: " + _fmt_bytes(stor))

    idx_raw = stats.get("totalIndexSize")
    if idx_raw != None:
        idx = int(idx_raw)
        levels_ix = params.get("levels_totalIndexSize")
        warn_ix = levels_ix[0] * 1024 if levels_ix != None else None
        crit_ix = levels_ix[1] * 1024 if levels_ix != None else None
        overall = _worst_state(overall, _threshold_state(idx, warn_ix, crit_ix))
        metrics["mongodb_collection_total_index_size"] = idx
        msg_parts.append("Index Size: " + _fmt_bytes(idx))

    nidx_raw = stats.get("nindexes")
    if nidx_raw != None:
        nidx = int(nidx_raw)
        overall = _worst_state(overall, _threshold_state(nidx, 62, 65))
        metrics["nindexes"] = nidx
        msg_parts.append("Indexes: %d" % nidx)

    detail_lines = ["Collection"]
    count_raw = stats.get("count")
    if count_raw != None:
        detail_lines.append("- Document Count: %d" % int(count_raw))
    avg_raw = stats.get("avgObjSize")
    if avg_raw != None:
        detail_lines.append("- Object Size: " + _fmt_bytes(int(avg_raw)))
    if size_raw != None:
        detail_lines.append("- Collection Size: " + _fmt_bytes(int(size_raw)))
    if stor_raw != None:
        detail_lines.append("- Storage Size: " + _fmt_bytes(int(stor_raw)))
    detail_lines.append("Indexes:")
    if idx_raw != None:
        detail_lines.append("- Total Index Size: " + _fmt_bytes(int(idx_raw)))
    if nidx_raw != None:
        detail_lines.append("- Number of Indexes: %d" % int(nidx_raw))

    msg = item + " - " + ", ".join(msg_parts) if msg_parts else item
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall,
            "metrics": metrics,
            "details": "\n".join(detail_lines),
        },
    }