def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mysql", "--defaults-extra-file=/root/.my.cnf", "-NBe", "SHOW SLAVE HOSTS;"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "mysql not installed", "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout.strip():
            hosts = []
        else:
            hosts = [h for h in res.stdout.splitlines() if h.strip()]
        if len(hosts) == 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        out = [{"item": "mysql", "params": {"seconds_behind_master": ("no_levels", None)}, "metrics": ["relay_log_space", "sync_latency"]}]
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["mysql", "--defaults-extra-file=/root/.my.cnf", "-NBe", "SHOW SLAVE STATUS;"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "mysql not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    out = res.stdout
    if res.rc != 0 or not out.strip():
        return {"changed": False, "msg": "no mysql slave status found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cols = ["Slave_IO_Running", "Slave_SQL_Running", "Seconds_Behind_Master", "Relay_Log_Space", "Relay_Master_Log_File", "Exec_Master_Log_Pos", "Master_Log_File", "Read_Master_Log_Pos", "Last_Errno", "Last_Error"]
    rows = [r.split("\t") for r in out.splitlines() if r.strip()]
    if len(rows) == 0:
        return {"changed": False, "msg": "no mysql slave status found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    header = [c.strip() for c in rows[0]]
    data = {}
    for i, col in enumerate(header):
        if col in cols:
            val = rows[1][i] if i < len(rows[1]) else ""
            if val == "NULL" or val == "":
                data[col] = "NULL"
            elif val in ("Yes", "No"):
                data[col] = True if val == "Yes" else False
            elif val.lstrip("-").isdigit():
                data[col] = int(val)
            else:
                data[col] = val
    if "Replica_IO_Running" in data:
        replica_or_slave = "Replica"
    else:
        replica_or_slave = "Slave"
    io_col = replica_or_slave + "_IO_Running"
    sql_col = replica_or_slave + "_SQL_Running"
    io_running = data.get(io_col, None)
    sql_running = data.get(sql_col, None)
    if io_running == True:
        io_msg = replica_or_slave + "-IO: running"
    else:
        io_msg = replica_or_slave + "-IO: not running"
    if sql_running == True:
        sql_msg = replica_or_slave + "-SQL: running"
    else:
        sql_msg = replica_or_slave + "-SQL: not running"
    sbm = None
    sbm_col = None
    if replica_or_slave == "Slave":
        sbm_col = "Seconds_Behind_Master"
        source_or_master = "master"
    else:
        sbm_col = "Seconds_Behind_Source"
        source_or_master = "source"
    sbm = data.get(sbm_col, None)
    rls = data.get("Relay_Log_Space", None)
    relay_metric = 0
    if rls == "NULL" or rls == None:
        relay_metric = 0
    else:
        relay_metric = rls if isinstance(rls, int) else 0
    warn = params.get("warn", None)
    crit = params.get("crit", None)
    sync_metric = 0
    if sbm == "NULL" or sbm == None:
        sync_metric = 0
        sbm_state = "CRIT"
    elif isinstance(sbm, int):
        sync_metric = sbm
        if warn != None:
            if (isinstance(warn, (list, tuple)) and len(warn) == 2):
                w = warn[0]
                c = warn[1]
                if sbm >= c:
                    sbm_state = "CRIT"
                elif sbm >= w:
                    sbm_state = "WARN"
                else:
                    sbm_state = "OK"
            elif isinstance(warn, (int, float)):
                if sbm >= warn:
                    sbm_state = "WARN"
                else:
                    sbm_state = "OK"
        else:
            sbm_state = "OK"
    else:
        sync_metric = 0
        sbm_state = "UNKNOWN"
    if io_running != True:
        io_state = "CRIT"
    else:
        io_state = "OK"
    if sql_running != True:
        sql_state = "CRIT"
    else:
        sql_state = "OK"
    states = [io_state, sql_state]
    if sbm_state != "UNKNOWN":
        states.append(sbm_state)
    if "CRIT" in states:
        overall = "CRIT"
    elif "WARN" in states:
        overall = "WARN"
    elif "UNKNOWN" in states:
        overall = "UNKNOWN"
    else:
        overall = "OK"
    parts = [io_msg, sql_msg]
    if sbm_state != "UNKNOWN":
        parts.append("Time behind %s: %s" % (source_or_master, sbm_state.lower()))
    msg = ", ".join(parts)
    return {"changed": False, "msg": msg, "data": {"state": overall, "metrics": {"relay_log_space": relay_metric, "sync_latency": sync_metric}, "details": ""}}