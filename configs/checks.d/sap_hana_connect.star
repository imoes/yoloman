# Checkmk check: sap_hana_connect
# Tests SAP HANA SQL connectivity; reports Worker / Standby state.
# Data gathered via hdbsql run as <sid>adm on the local HANA host.

_HDBSQL_CANDIDATES = [
    "/usr/sap/%s/HDB%s/exe/hdbsql",
    "/usr/sap/hdbclient/hdbsql",
]

_OK_CODES = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 16, 32, 64, 127, 255]


def _hdbsql_path(ctx, sid, inst):
    for c in _HDBSQL_CANDIDATES:
        p = c % (sid, inst) if c.count("%s") == 2 else c
        if ctx.file_exists(p):
            return p
    return "hdbsql"


def _parse_hana_dirs(ctx):
    if not ctx.file_exists("/usr/sap"):
        return []
    res = ctx.run(
        ["find", "/usr/sap", "-maxdepth", "2", "-mindepth", "2", "-type", "d"],
        mutates=False, ok_codes=[0, 1, 2],
    )
    seen = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split("/")
        if len(parts) < 5:
            continue
        sid = parts[3]
        hdb = parts[4]
        if (len(sid) == 3 and len(hdb) == 5 and
                hdb[:3] == "HDB" and hdb[3:].isdigit()):
            seen[sid + " " + hdb] = True
    return list(seen.keys())


def _su_cmd(sidadm, hdbsql, user, password, port, sql):
    cmd = (hdbsql + " -u " + user + " -p " + password +
           " -n localhost:" + port + " \"" + sql + "\"")
    return ["su", "-", sidadm, "-c", cmd]


def main(ctx, params):
    if params.get("_discover"):
        items = _parse_hana_dirs(ctx)
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA instances" % len(items),
            "data": {
                "discovery": [{"item": i, "params": {}, "metrics": []} for i in items],
            },
        }

    item = params.get("item", "")
    item_parts = item.split()
    if len(item_parts) < 2:
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sid = item_parts[0]
    hdb = item_parts[1]
    inst = hdb[3:]                     # "00" from "HDB00"
    sidadm = sid.lower() + "adm"
    port = "3" + inst + "13"           # 30013 for instance 00

    user = params.get("user", "SYSTEM")
    password = params.get("password", "")
    if password == "":
        return {"changed": False, "msg": "param 'password' is required",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    hdbsql = _hdbsql_path(ctx, sid, inst)

    role_sql = "SELECT MEMBER_TYPE FROM M_LANDSCAPE_HOST_CONFIGURATION WHERE IS_LOCAL_HOST='YES'"
    role_res = ctx.run(
        _su_cmd(sidadm, hdbsql, user, password, port, role_sql),
        mutates=False, ok_codes=_OK_CODES,
    )

    ts_sql = "SELECT NOW() FROM DUMMY"
    ts_res = ctx.run(
        _su_cmd(sidadm, hdbsql, user, password, port, ts_sql),
        mutates=False, ok_codes=_OK_CODES,
    )

    if role_res.rc == 127 and ts_res.rc == 127:
        return {"changed": False, "msg": "hdbsql not found",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "hdbsql binary not found on host"}}

    if role_res.rc != 0 or ts_res.rc != 0:
        err = (role_res.stderr.strip() if role_res.rc != 0 else ts_res.stderr.strip())
        return {"changed": False, "msg": "No connect",
                "data": {"state": "CRIT", "metrics": {}, "details": err}}

    # Map MEMBER_TYPE to worker / standby
    member_type = "WORKER"
    for line in role_res.stdout.splitlines():
        val = line.strip().strip('"').strip("|").strip().upper()
        if val == "STANDBY":
            member_type = "STANDBY"
        elif val == "WORKER":
            member_type = "WORKER"

    if member_type == "STANDBY":
        state = "OK"
        msg = "Standby: OK"
    else:
        state = "OK"
        msg = "Worker: OK"

    # Extract timestamp (YYYY-MM-DD HH:MM:SS)
    timestamp = "not found"
    for line in ts_res.stdout.splitlines():
        s = line.strip().strip('"')
        if (len(s) >= 19 and s[4] == "-" and s[7] == "-" and
                s[13] == ":" and s[16] == ":"):
            timestamp = s[:19]
            break

    # Extract driver version from hdbsql banner output
    driver_version = "not found"
    for src in [ts_res.stderr, ts_res.stdout, role_res.stderr, role_res.stdout]:
        for line in src.splitlines():
            line_lower = line.lower()
            if "version" in line_lower:
                idx = line_lower.find("version")
                candidate = line[idx + 7:].strip()
                if candidate:
                    tok = candidate.split()
                    driver_version = tok[0] if len(tok) > 0 else candidate
                    break
        if driver_version != "not found":
            break

    server_node = params.get("host", "localhost") + ":" + port
    details = (
        "ODBC Driver Version: " + driver_version +
        ", Server Node: " + server_node +
        ", Timestamp: " + timestamp
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": details},
    }