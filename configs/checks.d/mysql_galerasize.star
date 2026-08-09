def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mysql", "--version"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "mysql not found", "data": {"discovery": []}}
        host = params.get("host", "localhost")
        user = params.get("user", "")
        pw = params.get("password", "")
        socket = params.get("socket", "")
        connect_args = []
        if user != "":
            connect_args = connect_args + ["-u", user]
            if pw != "":
                connect_args = connect_args + ["-p" + pw]
        if socket != "":
            connect_args = connect_args + ["-S", socket]
        else:
            connect_args = connect_args + ["-h", host]
        out = _query_mysql(ctx, connect_args, "SHOW GLOBAL STATUS")
        if out.rc != 0:
            return {"changed": False, "msg": "cannot query SHOW GLOBAL STATUS", "data": {"discovery": []}}
        wsrep_provider = _extract_var(out.stdout, "wsrep_provider")
        if wsrep_provider == None or wsrep_provider == "none":
            return {"changed": False, "msg": "no wsrep provider", "data": {"discovery": []}}
        vars_out = _query_mysql(ctx, connect_args, "SHOW GLOBAL VARIABLES")
        if vars_out.rc != 0:
            return {"changed": False, "msg": "cannot query SHOW GLOBAL VARIABLES", "data": {"discovery": []}}
        cluster_size = _extract_var(vars_out.stdout, "wsrep_cluster_size")
        if cluster_size == None:
            return {"changed": False, "msg": "no wsrep_cluster_size", "data": {"discovery": []}}
        size = int(cluster_size) if _is_int(cluster_size) else 0
        discovery = [
            {"item": "mysql", "params": {"invsize": size}, "metrics": []}
        ]
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    user = params.get("user", "")
    pw = params.get("password", "")
    socket = params.get("socket", "")
    connect_args = []
    if user != "":
        connect_args = connect_args + ["-u", user]
        if pw != "":
            connect_args = connect_args + ["-p" + pw]
    if socket != "":
        connect_args = connect_args + ["-S", socket]
    else:
        connect_args = connect_args + ["-h", host]
    out = _query_mysql(ctx, connect_args, "SHOW GLOBAL STATUS")
    if out.rc != 0:
        return {"changed": False, "msg": "no mysql instance found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    wsrep_provider = _extract_var(out.stdout, "wsrep_provider")
    if wsrep_provider == None or wsrep_provider == "none":
        return {"changed": False, "msg": "no wsrep provider", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vars_out = _query_mysql(ctx, connect_args, "SHOW GLOBAL VARIABLES")
    if vars_out.rc != 0:
        return {"changed": False, "msg": "cannot query wsrep_cluster_size", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cluster_size = _extract_var(vars_out.stdout, "wsrep_cluster_size")
    if cluster_size == None:
        return {"changed": False, "msg": "wsrep_cluster_size missing", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    size = int(cluster_size) if _is_int(cluster_size) else 0
    invsize = params.get("invsize", size)
    state = "OK"
    if size != invsize:
        state = "CRIT"
    detail = "WSREP cluster size: %d" % size
    if size != invsize:
        detail = detail + " (at discovery: %d)" % invsize
    return {"changed": False, "msg": detail, "data": {"state": state, "metrics": {"cluster_size": size}, "details": detail}}


def _query_mysql(ctx, connect_args, query):
    return ctx.run(["mysql"] + connect_args + ["-N", "-B", "-e", query], mutates=False)


def _extract_var(stdout, name):
    for line in stdout.splitlines():
        cols = line.split("\t")
        if len(cols) >= 2:
            if cols[0] == name:
                return cols[1]
    return None


def _is_int(s):
    if s == None:
        return False
    if len(s) == 0:
        return False
    for c in s:
        if c not in "0123456789":
            return False
    return True