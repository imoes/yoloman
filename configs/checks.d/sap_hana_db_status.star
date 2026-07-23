MAP_DB_STATUS = {"OK": "OK", "WARNING": "WARN"}
DB_STATUS_VALUES = ["OK", "WARNING", "ERROR", "STARTING", "STOPPING"]
REPL_ROLE_VALUES = ["PRIMARY", "SECONDARY", "NONE"]

def _run_hdbsql(ctx, sid, instance_num, user, password, key_user_store, query):
    if key_user_store != "":
        auth = "-U " + key_user_store
    else:
        auth = "-u " + user + " -p " + password
    cmd_str = "hdbsql -i " + instance_num + " -d SYSTEMDB " + auth + " -x \"" + query + "\""
    return ctx.run(
        ["su", "-", sid.lower() + "adm", "-c", cmd_str],
        mutates=False,
        ok_codes=[0, 1, 2, 3, 4, 127, 255],
    )

def _extract_value(output, valid_values):
    for line in output.splitlines():
        val = line.strip().strip('"')
        if val in valid_values:
            return val
    return ""

def _find_instances(ctx):
    instances = []
    if not ctx.file_exists("/usr/sap"):
        return instances
    res = ctx.run(
        ["find", "/usr/sap", "-maxdepth", "2", "-mindepth", "2", "-type", "d"],
        mutates=False,
        ok_codes=[0, 1],
    )
    for line in res.stdout.splitlines():
        parts = line.strip().split("/")
        if len(parts) < 5:
            continue
        sid = parts[3]
        hdb_dir = parts[4]
        if len(sid) == 3 and hdb_dir.startswith("HDB") and len(hdb_dir) == 5:
            inst = hdb_dir[3:]
            if inst.isdigit():
                instances.append((sid, inst))
    return instances

def main(ctx, params):
    user = params.get("user", "SYSTEM")
    password = params.get("password", "")
    key_user_store = params.get("key_user_store", "")

    if params.get("_discover"):
        instances = _find_instances(ctx)
        discovery = [
            {"item": pair[0] + " " + pair[1], "params": {}, "metrics": []}
            for pair in instances
        ]
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    parts = item.split(" ")
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sid = parts[0]
    instance_num = parts[1]

    res = _run_hdbsql(ctx, sid, instance_num, user, password, key_user_store,
                      "SELECT STATUS FROM SYS.M_DATABASE")
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Login into database failed.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    status = _extract_value(res.stdout, DB_STATUS_VALUES)
    if not status:
        return {
            "changed": False,
            "msg": "Login into database failed.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = MAP_DB_STATUS.get(status, "CRIT")

    if state == "CRIT":
        repl_res = _run_hdbsql(ctx, sid, instance_num, user, password, key_user_store,
                               "SELECT SYSTEM_REPLICATION_ROLE FROM SYS.M_DATABASE")
        if repl_res.rc == 0 and repl_res.stdout.strip():
            role = _extract_value(repl_res.stdout, REPL_ROLE_VALUES)
            if role == "SECONDARY":
                return {
                    "changed": False,
                    "msg": "System is in passive mode",
                    "data": {"state": "OK", "metrics": {}, "details": ""},
                }

    return {
        "changed": False,
        "msg": status,
        "data": {"state": state, "metrics": {}, "details": ""},
    }