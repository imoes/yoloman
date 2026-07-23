SAP_BASE = "/usr/sap"
_DIGITS = "0123456789"

def _is_digit_str(s):
    if not s:
        return False
    for i in range(len(s)):
        if _DIGITS.find(s[i:i+1]) < 0:
            return False
    return True

def _safe_int(s, default):
    s = s.strip().strip('"')
    if not _is_digit_str(s):
        return default
    return int(s)

def _parse_first_value(stdout):
    for line in stdout.splitlines():
        line = line.strip()
        if line and not line.startswith("Connected") and not line.startswith("HDBSQL"):
            return line.strip('"')
    return ""

def _run_sql(ctx, sid, nr, user, password, store_key, sql):
    inst_nr = nr if len(nr) == 2 else ("0" + nr)
    sidadm = sid.lower() + "adm"
    if store_key != "":
        inner = "hdbsql -U " + store_key + " -a -x '" + sql + "'"
    elif user != "" and password != "":
        inner = "hdbsql -i " + inst_nr + " -u " + user + " -p " + password + " -a -x '" + sql + "'"
    else:
        inner = "hdbsql -i " + inst_nr + " -a -x '" + sql + "'"
    return ctx.run(["su", "-", sidadm, "-c", inner], mutates=False, ok_codes=[0, 1, 2, 3, 4])

def _find_instances(ctx):
    items = []
    res = ctx.run(["ls", SAP_BASE], mutates=False, ok_codes=[0, 1, 2])
    if res.rc != 0:
        return items
    for sid in res.stdout.split():
        if len(sid) != 3:
            continue
        res2 = ctx.run(["ls", SAP_BASE + "/" + sid], mutates=False, ok_codes=[0, 1, 2])
        if res2.rc != 0:
            continue
        for entry in res2.stdout.split():
            if not entry.startswith("HDB"):
                continue
            nr = entry[3:]
            if _is_digit_str(nr) and len(nr) >= 1:
                items.append(sid + " " + nr)
    return items

def main(ctx, params):
    user = params.get("user", "")
    password = params.get("password", "")
    store_key = params.get("store_key", "")

    if params.get("_discover"):
        items = _find_instances(ctx)
        discovery = []
        for item in items:
            parts = item.split()
            sid = parts[0]
            nr = parts[1]
            res = _run_sql(ctx, sid, nr, user, password, store_key,
                           "SELECT COUNT(*) FROM SYS.M_EXTENDED_STORAGE_SERVICES")
            count = _safe_int(_parse_first_value(res.stdout), 0)
            if res.rc == 0 and count > 0:
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": ["threads"],
                })
        return {
            "changed": False,
            "msg": "discovered %d ESS instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    parts = item.split()
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sid = parts[0]
    nr = parts[1]

    res_a = _run_sql(ctx, sid, nr, user, password, store_key,
                     "SELECT LOWER(CAST(ACTIVE AS NVARCHAR(20))) FROM SYS.M_EXTENDED_STORAGE_SERVICES")
    if res_a.rc != 0 or not res_a.stdout.strip():
        return {
            "changed": False,
            "msg": "Login into database failed.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res_a.stderr},
        }

    active_val = _parse_first_value(res_a.stdout)
    if not active_val:
        active_val = "unknown"

    if active_val == "unknown":
        active_state = "UNKNOWN"
    elif active_val in ["false", "no"]:
        active_state = "CRIT"
    else:
        active_state = "OK"

    res_t = _run_sql(ctx, sid, nr, user, password, store_key,
                     "SELECT COUNT(*) FROM SYS.M_SERVICE_THREADS WHERE SERVICE_NAME LIKE 'extended%'")
    started_threads = 0
    if res_t.rc == 0 and res_t.stdout.strip():
        started_threads = _safe_int(_parse_first_value(res_t.stdout), 0)

    thread_state = "CRIT" if started_threads < 1 else "OK"

    state_prio = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    overall = "OK"
    for s in [active_state, thread_state]:
        if state_prio.get(s, 0) > state_prio.get(overall, 0):
            overall = s

    msg = "Active status: %s, Started threads: %d" % (active_val, started_threads)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall,
            "metrics": {"threads": started_threads},
            "details": "",
        },
    }