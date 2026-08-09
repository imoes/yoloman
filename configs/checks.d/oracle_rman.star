# Checkmk check: oracle_rman → read-only Starlark check module
# Monitors Oracle RMAN backup age per SID. Data source: on-host SQL*Plus
# query against the Oracle instance(s). READ-ONLY: no mutations.

def _safe_int(s):
    if s == None or s == "":
        return None
    digits = s
    if digits.startswith("-"):
        digits = digits[1:]
    if digits.isdigit():
        return int(s)
    return None

def _parse_line(line):
    parts = line.split("|")
    if len(parts) == 6:
        sid = parts[0]
        status = parts[1]
        btype = parts[4]
        bage = parts[5]
        level = "-1"
        scn = "-1"
    elif len(parts) == 8:
        sid = parts[0]
        status = parts[1]
        btype = parts[4]
        level = parts[5]
        bage = parts[6]
        scn = parts[7]
        if scn == "":
            scn = "-1"
    else:
        return None
    age = _safe_int(bage)
    if age != None:
        age = max(age, 0)
    scn_val = _safe_int(scn)
    if scn_val == None:
        scn_val = -1
    if btype == "DB_INCR":
        item = "%s.%s_%s" % (sid, btype, level)
    else:
        item = "%s.%s" % (sid, btype)
    return {
        "item": item,
        "sid": sid,
        "backuptype": btype,
        "backuplevel": level,
        "backupage": age,
        "status": status,
        "backupscn": scn_val,
        "used_incr_0": False,
    }

def _query_rman(ctx, sid, password, host):
    sql_lines = [
        "set heading off",
        "set feedback off",
        "set pagesize 0",
        "set trimspool on",
        "set echo off",
        "set linesize 200",
        "SELECT s.sid, s.status, s.start_time, s.completion_time, s.backup_type, CEIL((SYSDATE - s.completion_time) * 24 * 60), s.incremental_level, s.checkpoint_change FROM v$rman_status s WHERE s.status IN ('COMPLETED','COMPLETED WITH WARNINGS') AND s.backup_type IN ('D','I') ORDER BY s.completion_time DESC;",
        "exit",
    ]
    conn_str = "%s/%s@%s/ORCL as sysdba" % (sid, password, host)
    cmd = ["sqlplus", "-s", conn_str]
    return ctx.run(cmd, mutates=False, input="\n".join(sql_lines) + "\n")

def main(ctx, params):
    if params.get("_discover"):
        ora_home = ctx.file_exists("/etc/oratab")
        if not ora_home:
            return {"changed": False, "msg": "no oratab found, oracle_rman not applicable",
                    "data": {"discovery": []}}
        res = ctx.file_read("/etc/oratab")
        sids = []
        for line in res.splitlines():
            if line.startswith("#") or not line.strip():
                continue
            parts = line.split(":")
            if len(parts) >= 4 and parts[3] == "Y":
                sids.append(parts[0])
        if not sids:
            return {"changed": False, "msg": "no enabled oracle instances found",
                    "data": {"discovery": []}}
        discovery = []
        for sid in sids:
            for bt in ("ARCHIVELOG", "DB_FULL", "DB_INCR_0", "DB_INCR_1", "CONTROLFILE"):
                discovery.append({
                    "item": "%s.%s" % (sid, bt),
                    "params": {"levels": (None, None)},
                    "metrics": ["age"],
                })
        return {"changed": False,
                "msg": "discovered %d rman items" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parts = item.split(".")
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sid = parts[0]
    btype = parts[1]
    password = params.get("password", "")
    host = params.get("host", "localhost")
    res = _query_rman(ctx, sid, password, host)
    if res.rc != 0:
        return {"changed": False,
                "msg": "no data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "oracle not reachable"}}
    raw = res.stdout
    if raw == None or raw == "":
        return {"changed": False,
                "msg": "no data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "oracle not reachable"}}
    lines = [l for l in raw.splitlines() if "|" in l]
    section = {}
    for l in lines:
        parsed = _parse_line(l)
        if parsed:
            section[parsed["item"]] = parsed
    rman = section.get(item)
    if not rman:
        if item.endswith("1"):
            alt = item[:-1] + "0"
            rman = section.get(alt)
            if rman:
                rman["used_incr_0"] = True
        if not rman:
            return {"changed": False,
                    "msg": "no backup found for " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = rman["status"]
    if status not in ("COMPLETED", "COMPLETED WITH WARNINGS"):
        return {"changed": False,
                "msg": "no COMPLETED backup found for " + item,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    age = rman["backupage"]
    levels = params.get("levels", (None, None))
    warn = levels[0] if len(levels) > 0 else None
    crit = levels[1] if len(levels) > 1 else None
    if age == None:
        return {"changed": False,
                "msg": "unknown backupage for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    metrics = {"age": age}
    state = "OK"
    if crit != None and age >= crit:
        state = "CRIT"
    elif warn != None and age >= warn:
        state = "WARN"
    details = "SID: %s, Type: %s, Age: %d minutes" % (sid, btype, age)
    msg = "%s age: %d min" % (item, age)
    if state == "CRIT":
        msg = "CRIT - " + msg
    elif state == "WARN":
        msg = "WARN - " + msg
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}