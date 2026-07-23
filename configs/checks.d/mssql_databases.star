AUTO_STATE_MAP = {
    "1": "on",
    "0": "off",
}

def _sqlcmd_args(params):
    host = params.get("host", "localhost")
    instance = params.get("instance", "")
    if instance != "":
        server = host + "\\" + instance
    else:
        server = host
    cmd = ["sqlcmd", "-S", server, "-h", "-1", "-W", "-s", "|"]
    user = params.get("user", "")
    if user != "":
        cmd = cmd + ["-U", user, "-P", params.get("password", "")]
    else:
        cmd = cmd + ["-E"]
    return cmd

def _instance_prefix(params):
    pref = params.get("instance_prefix", "")
    if pref != "":
        return pref
    inst = params.get("instance", "")
    if inst != "":
        return "MSSQL_" + inst.upper()
    return "MSSQL_MSSQLSERVER"

def _parse_output(stdout, prefix):
    dbs = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) < 5:
            continue
        dbname = parts[0].strip()
        status = parts[1].strip()
        recovery = parts[2].strip()
        ac = parts[3].strip()
        ashrink = parts[4].strip()
        if not dbname or dbname.startswith("-"):
            continue
        key = prefix + " " + dbname
        dbs[key] = {
            "DBname": dbname,
            "Instance": prefix,
            "Status": status,
            "Recovery": recovery,
            "auto_close": ac,
            "auto_shrink": ashrink,
        }
    return dbs

def _worst(current, candidate_int):
    if candidate_int == 2 and current != "CRIT":
        return "CRIT"
    if candidate_int == 1 and current == "OK":
        return "WARN"
    return current

def main(ctx, params):
    prefix = _instance_prefix(params)
    query = (
        "SET NOCOUNT ON; " +
        "SELECT name, state_desc, recovery_model_desc, " +
        "CAST(is_auto_close_on AS TINYINT), CAST(is_auto_shrink_on AS TINYINT) " +
        "FROM sys.databases ORDER BY name"
    )
    cmd = _sqlcmd_args(params) + ["-Q", query]
    res = ctx.run(cmd, mutates=False, ok_codes=[0, 1])

    if params.get("_discover"):
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "sqlcmd error: " + res.stderr,
                "data": {"discovery": []},
            }
        dbs = _parse_output(res.stdout, prefix)
        items = []
        for key in sorted(dbs.keys()):
            items.append({"item": key, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d databases" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "sqlcmd error: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    dbs = _parse_output(res.stdout, prefix)
    data = dbs.get(item)

    if data == None:
        return {
            "changed": False,
            "msg": "Login into database failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    db_state = data["Status"]

    if db_state.startswith("ERROR: "):
        return {
            "changed": False,
            "msg": db_state[7:],
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    map_db_states = params.get("map_db_states", {})
    state_key = db_state.replace(" ", "_").upper()
    state_int = map_db_states.get(state_key, 0)
    state = "CRIT" if state_int == 2 else ("WARN" if state_int == 1 else "OK")

    summary = ["Status: " + db_state, "Recovery: " + data["Recovery"]]

    for what in ["close", "shrink"]:
        raw_val = data.get("auto_" + what, "0")
        readable = AUTO_STATE_MAP.get(raw_val, "off")
        raw_int = int(raw_val) if raw_val.isdigit() else 0
        mapped = params.get("map_auto_" + what + "_state", {})
        what_int = mapped.get(readable, raw_int)
        state = _worst(state, what_int)
        summary.append("Auto " + what + ": " + readable)

    return {
        "changed": False,
        "msg": ", ".join(summary),
        "data": {"state": state, "metrics": {}, "details": ""},
    }