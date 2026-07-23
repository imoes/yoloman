def main(ctx, params):
    if params.get("_discover"):
        env = {}
        env_str = ctx.run(["env"], mutates=False).stdout
        for line in env_str.splitlines():
            if line.find("=") != -1:
                k, v = line.split("=", 1)
                env[k] = v

        conn_str = "/ as sysdba"
        if params.get("username") != None and params.get("password") != None:
            conn_str = "%s/%s" % (params.get("username"), params.get("password"))
            if params.get("database") != None:
                conn_str = conn_str + "@" + params.get("database")

        sqlplus_cmd = "sqlplus"
        if ctx.file_exists("/oracle/product/19c/dbhome_1/bin/sqlplus"):
            sqlplus_cmd = "/oracle/product/19c/dbhome_1/bin/sqlplus"
        elif ctx.file_exists("/oracle/product/12.2.0.1/dbhome_1/bin/sqlplus"):
            sqlplus_cmd = "/oracle/product/12.2.0.1/dbhome_1/bin/sqlplus"
        elif ctx.file_exists("/usr/bin/sqlplus"):
            sqlplus_cmd = "/usr/bin/sqlplus"

        sql_query = "SELECT UPPER(instance_name), activeblks, maxconcurrency, tuned_undoretention, maxquerylen, nospaceerrcnt FROM v$undostat JOIN v$instance using (instance_number) WHERE rownum = 1"
        res = ctx.run([sqlplus_cmd, "-S", conn_str, "-L"], mutates=False)

        if res.rc != 0:
            return {"changed": False, "msg": "no oracle undostat data available",
                    "data": {"discovery": []}}

        output = res.stdout.strip()
        if not output:
            return {"changed": False, "msg": "no oracle undostat data available",
                    "data": {"discovery": []}}

        parts = output.split()
        if len(parts) != 6:
            return {"changed": False, "msg": "unexpected undostat data format",
                    "data": {"discovery": []}}

        instance_name = parts[0]
        return {
            "changed": False,
            "msg": "discovered 1 instance",
            "data": {"discovery": [
                {"item": instance_name, "params": {
                    "levels": (600, 300),
                    "nospaceerrcnt_state": 2,
                }, "metrics": ["tunedretention", "activeblk", "transconcurrent", "querylen", "nonspaceerrcount"]}
            ]},
        }

    item = params.get("item", "")

    env = {}
    env_str = ctx.run(["env"], mutates=False).stdout
    for line in env_str.splitlines():
        if line.find("=") != -1:
            k, v = line.split("=", 1)
            env[k] = v

    conn_str = "/ as sysdba"
    if params.get("username") != None and params.get("password") != None:
        conn_str = "%s/%s" % (params.get("username"), params.get("password"))
        if params.get("database") != None:
            conn_str = conn_str + "@" + params.get("database")

    sqlplus_cmd = "sqlplus"
    if ctx.file_exists("/oracle/product/19c/dbhome_1/bin/sqlplus"):
        sqlplus_cmd = "/oracle/product/19c/dbhome_1/bin/sqlplus"
    elif ctx.file_exists("/oracle/product/12.2.0.1/dbhome_1/bin/sqlplus"):
        sqlplus_cmd = "/oracle/product/12.2.0.1/dbhome_1/bin/sqlplus"
    elif ctx.file_exists("/usr/bin/sqlplus"):
        sqlplus_cmd = "/usr/bin/sqlplus"

    sql_query = "SELECT UPPER(instance_name), activeblks, maxconcurrency, tuned_undoretention, maxquerylen, nospaceerrcnt FROM v$undostat JOIN v$instance using (instance_number) WHERE rownum = 1"
    res = ctx.run([sqlplus_cmd, "-S", conn_str, "-L"], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Login into database failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    output = res.stdout.strip()
    if not output:
        return {
            "changed": False,
            "msg": "Login into database failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    parts = output.split()
    if len(parts) != 6:
        return {
            "changed": False,
            "msg": "unexpected undostat data format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    instance_name = parts[0]
    if instance_name != item:
        return {
            "changed": False,
            "msg": "instance mismatch",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    activeblks = int(parts[1]) if parts[1].isdigit() else 0
    maxconcurrency = int(parts[2]) if parts[2].isdigit() else 0
    tuned_undoretention = int(parts[3]) if parts[3].isdigit() else 0
    maxquerylen = int(parts[4]) if parts[4].isdigit() else 0
    nospaceerrcnt = int(parts[5]) if parts[5].isdigit() else 0

    warn, crit = params.get("levels", (600, 300))
    nospaceerrcnt_state = params.get("nospaceerrcnt_state", 2)

    if tuned_undoretention == -1:
        state = "OK"
    else:
        if tuned_undoretention <= crit:
            state = "CRIT"
        elif tuned_undoretention <= warn:
            state = "WARN"
        else:
            state = "OK"

    if tuned_undoretention == -1:
        retention_msg = "%d" % tuned_undoretention
    elif tuned_undoretention >= 3600:
        hours = tuned_undoretention // 3600
        minutes = (tuned_undoretention % 3600) // 60
        retention_msg = "%dh %dm" % (hours, minutes)
    elif tuned_undoretention >= 60:
        minutes = tuned_undoretention // 60
        seconds = tuned_undoretention % 60
        retention_msg = "%dm %ds" % (minutes, seconds)
    else:
        retention_msg = "%ds" % tuned_undoretention

    maxquerylen_msg = ""
    if maxquerylen >= 60:
        maxquerylen_msg = "%dm %ds" % (maxquerylen // 60, maxquerylen % 60)
    else:
        maxquerylen_msg = "%ds" % maxquerylen

    if tuned_undoretention >= 0:
        msg = "Undo retention: %s, Active undo blocks: %d, Max concurrent transactions: %d, Max querylen: %s, Space errors: %d" % (
            retention_msg, activeblks, maxconcurrency, maxquerylen_msg, nospaceerrcnt
        )
    else:
        msg = "Undo retention: %s, Max concurrent transactions: %d, Max querylen: %s, Space errors: %d" % (
            retention_msg, maxconcurrency, maxquerylen_msg, nospaceerrcnt
        )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "activeblk": activeblks,
                "transconcurrent": maxconcurrency,
                "tunedretention": tuned_undoretention,
                "querylen": maxquerylen,
                "nonspaceerrcount": nospaceerrcnt
            },
            "details": ""
        }
    }