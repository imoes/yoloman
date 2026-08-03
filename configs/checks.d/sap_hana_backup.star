def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["hdbsql", "--version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "hdbsql not installed", "data": {"discovery": []}}
        host = params.get("host", "localhost")
        port = params.get("port", "30015")
        user = params.get("user", "SYSTEM")
        secret = params.get("secret", "hdbsql_secret")
        res = ctx.run([
            "hdbsql", "-n", host + ":" + port, "-u", user,
            "-S", secret, "-j", "-e", "SELECT 1 FROM M_DATABASE",
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no SAP HANA database reachable", "data": {"discovery": []}}
        res2 = ctx.run([
            "hdbsql", "-n", host + ":" + port, "-u", user,
            "-S", secret, "-j", "-e",
            "SELECT HOST, START_TIME, STATE_NAME, ENTRY_TYPE_NAME FROM M_BACKUP_CATALOG WHERE ENTRY_TYPE_NAME = 'complete' ORDER BY START_TIME DESC",
        ], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "hdbsql query failed: " + res2.stderr, "data": {"discovery": []}}
        discovery = []
        lines = res2.stdout.strip().splitlines()
        if len(lines) < 1:
            return {"changed": False, "msg": "no SAP HANA backup data", "data": {"discovery": []}}
        seen = set()
        i = 1
        while i < len(lines):
            line = lines[i]
            i = i + 1
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            host_name = parts[0].strip()
            item = host_name
            if item in seen:
                continue
            seen.add(item)
            discovery.append({
                "item": item,
                "params": {"backup_age": (24 * 60 * 60, 2 * 24 * 60 * 60)},
                "metrics": ["backup_age"],
            })
        return {"changed": False, "msg": "discovered %d SAP HANA backup items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    port = params.get("port", "30015")
    user = params.get("user", "SYSTEM")
    secret = params.get("secret", "hdbsql_secret")
    probe = ctx.run(["hdbsql", "--version"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "hdbsql not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run([
        "hdbsql", "-n", host + ":" + port, "-u", user,
        "-S", secret, "-j", "-e",
        "SELECT HOST, START_TIME, STATE_NAME, ENTRY_TYPE_NAME, SYS_START_TIME FROM M_BACKUP_CATALOG WHERE ENTRY_TYPE_NAME = 'complete' ORDER BY START_TIME DESC LIMIT 1",
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "hdbsql query failed: " + res.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.strip().splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "Login into database failed.", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parts = lines[1].split("\t")
    if len(parts) < 5:
        return {"changed": False, "msg": "Login into database failed.", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state_name = parts[2].strip()
    start_time_str = parts[1].strip()
    if not state_name:
        return {"changed": False, "msg": "No backup found", "data": {"state": "WARN", "metrics": {}, "details": ""}}
    if state_name == "failed":
        state = "CRIT"
    elif state_name == "cancel pending" or state_name == "canceled":
        state = "WARN"
    elif state_name == "ok" or state_name == "successful" or state_name == "running":
        state = "OK"
    else:
        state = "UNKNOWN"
    msg = "Status: %s" % state_name
    metrics = {}
    details = ""
    if "." in start_time_str:
        ts_str = start_time_str.rsplit(".", 1)[0]
    else:
        ts_str = start_time_str
    if ts_str:
        epoch_res = ctx.run([
            "hdbsql", "-n", host + ":" + port, "-u", user,
            "-S", secret, "-j", "-e", "SELECT SECONDS_BETWEEN(NOW(), TIMESTAMP '%s')" % ts_str,
        ], mutates=False)
        if epoch_res.rc == 0:
            age_lines = epoch_res.stdout.strip().splitlines()
            if len(age_lines) >= 2:
                age_val = age_lines[1].strip()
                if len(age_val) > 0 and age_val != "NULL":
                    try_age = age_val.replace(".", "").replace("-", "")
                    if try_age.isdigit():
                        age = int(float(age_val))
                        if age >= 0:
                            metrics["backup_age"] = age
    levels = params.get("backup_age", (24 * 60 * 60, 2 * 24 * 60 * 60))
    warn = levels[0]
    crit = levels[1]
    if "backup_age" in metrics:
        age = metrics["backup_age"]
        if age >= crit:
            level_state = "CRIT"
        elif age >= warn:
            level_state = "WARN"
        else:
            level_state = "OK"
        state = _worst_state(state, level_state)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}


def _worst_state(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(a, 3) >= order.get(b, 3):
        return a
    return b