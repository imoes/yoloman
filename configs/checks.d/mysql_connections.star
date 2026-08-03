def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mysql", "--version"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no mysql instance found",
                    "data": {"discovery": []}}
        res = ctx.run(
            ["mysql", "--raw", "--batch", "--skip-column-names", "-e", "SHOW VARIABLES"],
            mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no mysql instance found",
                    "data": {"discovery": []}}
        discovery = []
        has_connections = False
        for line in res.stdout.splitlines():
            f = line.split("\t")
            if len(f) < 2:
                continue
            var = f[0]
            if var == "Max_used_connections":
                has_connections = True
            if var in ("Max_used_connections", "max_connections", "Threads_connected"):
                discovery.append({"item": var, "params": {"conn_warn": 80, "conn_crit": 90},
                                  "metrics": ["perc_used"]})
        if not has_connections:
            return {"changed": False, "msg": "no mysql instance found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered mysql connections",
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if item not in ("Max_used_connections", "max_connections", "Threads_connected"):
        return {"changed": False, "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["mysql", "--raw", "--batch", "--skip-column-names", "-e", "SHOW VARIABLES"],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no mysql instance found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = {}
    for line in res.stdout.splitlines():
        f = line.split("\t")
        if len(f) < 2:
            continue
        data[f[0]] = f[1]

    if "Max_used_connections" not in data:
        return {"changed": False, "msg": "connection information is missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    conn = float(data["Max_used_connections"])
    conn_threads = float(data["Threads_connected"])
    max_conn = float(data.get("max_connections", "1"))
    if max_conn == 0:
        max_conn = 1.0
    perc_used = conn / max_conn * 100
    perc_conn_threads = conn_threads / max_conn * 100

    conn_warn = params.get("conn_warn", 80)
    conn_crit = params.get("conn_crit", 90)
    state = "CRIT" if perc_used >= conn_crit else ("WARN" if perc_used >= conn_warn else "OK")

    return {"changed": False,
            "msg": "%f%% of max connections used (max: %d, current: %d)" % (
                perc_used, int(max_conn), int(conn_threads)),
            "data": {"state": state,
                     "metrics": {"connections_perc_used": perc_used},
                     "details": ""}}