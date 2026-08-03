def _parse_mysql_status(output):
    data = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        key = parts[0]
        val = parts[1]
        if val.lstrip("-").isdigit():
            data[key] = int(val)
        else:
            data[key] = val
    return data

def _is_galera(data):
    provider = data.get("wsrep_provider")
    if provider == None:
        return False
    if provider == "none":
        return False
    return True

def _read_wsrep_status(ctx):
    res = ctx.run(["mysql", "-B", "-N", "-e", "SHOW VARIABLES LIKE 'wsrep%';"], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    wsrep_vars = {}
    for line in lines:
        f = line.split()
        if len(f) < 2:
            continue
        name = f[0]
        value = f[1]
        if name.startswith("wsrep_"):
            wsrep_vars[name] = value
    if not wsrep_vars:
        return None
    return wsrep_vars

def main(ctx, params):
    if params.get("_discover"):
        wsrep = _read_wsrep_status(ctx)
        if wsrep == None:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        if not _is_galera(wsrep):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        if "wsrep_cluster_status" not in wsrep:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        out = [{"item": "", "params": {}, "metrics": []}]
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    wsrep = _read_wsrep_status(ctx)
    if wsrep == None:
        return {"changed": False, "msg": "no Galera cluster status available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    wsrep_cluster_status = wsrep.get("wsrep_cluster_status")
    if wsrep_cluster_status == None:
        return {"changed": False, "msg": "no Galera cluster status available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = "OK" if wsrep_cluster_status == "Primary" else "CRIT"
    return {"changed": False, "msg": "WSREP cluster status: %s" % wsrep_cluster_status, "data": {"state": state, "metrics": {}, "details": ""}}