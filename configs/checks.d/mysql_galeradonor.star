def _parse_mysql(string_table):
    data = {}
    for line in string_table:
        if len(line) < 2:
            continue
        key = line[0]
        raw = line[1]
        val = int(raw) if raw.lstrip("-").isdigit() else raw
        data[key] = val
    return data

def _gather_mysql_instances(ctx):
    res = ctx.run(["mysql", "-N", "-B", "-e", "SHOW VARIABLES WHERE Variable_name IN ('wsrep_provider','wsrep_sst_donor','wsrep_local_state_comment','wsrep_cluster_address','wsrep_cluster_size','wsrep_cluster_status')"], mutates=False)
    out = []
    if res.rc == 127:
        return out
    if res.rc != 0 or not res.stdout:
        return out
    lines = res.stdout.splitlines()
    inst = "mysql"
    grouped = {}
    for line in lines:
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        grouped.setdefault(inst, {})[parts[0]] = parts[1]
    parsed = {}
    for k, v in grouped.items():
        parsed[k] = _parse_mysql([list(x) for x in v.items()])
    return parsed

def _has_wsrep_provider(data):
    provider = data.get("wsrep_provider")
    return provider not in (None, "none")

def main(ctx, params):
    if params.get("_discover"):
        instances = _gather_mysql_instances(ctx)
        if not instances:
            return {"changed": False, "msg": "no mysql found", "data": {"discovery": []}}
        discovery = []
        for instance, data in instances.items():
            if _has_wsrep_provider(data) and "wsrep_sst_donor" in data:
                discovery.append({"item": instance, "params": {"wsrep_sst_donor": data["wsrep_sst_donor"]}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    instances = _gather_mysql_instances(ctx)
    if not instances:
        return {"changed": False, "msg": "no mysql found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = instances.get(item)
    if data == None or not _has_wsrep_provider(data) or "wsrep_sst_donor" not in data:
        return {"changed": False, "msg": "no such item: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    wsrep_sst_donor = data.get("wsrep_sst_donor")
    if wsrep_sst_donor == None:
        return {"changed": False, "msg": "wsrep_sst_donor missing", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = "OK"
    infotext = "WSREP SST donor: %s" % wsrep_sst_donor
    p_wsrep_sst_donor = params.get("wsrep_sst_donor")
    if p_wsrep_sst_donor != None and wsrep_sst_donor != p_wsrep_sst_donor:
        state = "WARN"
        infotext = infotext + " (at discovery: %s)" % p_wsrep_sst_donor
    return {"changed": False, "msg": infotext, "data": {"state": state, "metrics": {}, "details": ""}}