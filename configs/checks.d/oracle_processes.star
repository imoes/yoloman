ORATAB_PATHS = ["/etc/oratab", "/var/opt/oracle/oratab"]
SQL_BODY = "SET HEADING OFF\nSET FEEDBACK OFF\nSET PAGESIZE 0\nSET TRIMOUT ON\nSELECT (SELECT count(*) FROM v$process)||' '||(SELECT TO_NUMBER(value) FROM v$parameter WHERE name='processes') FROM dual;\nEXIT;"

def _parse_oratab(content):
    instances = []
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split(":")
        if len(parts) < 2:
            continue
        sid = parts[0].strip()
        ohome = parts[1].strip()
        if sid and sid != "*" and ohome:
            instances.append({"sid": sid, "oracle_home": ohome})
    return instances

def _find_oratab_instances(ctx):
    for path in ORATAB_PATHS:
        if ctx.file_exists(path):
            return _parse_oratab(ctx.file_read(path))
    return []

def _run_sqlplus(ctx, sid, oracle_home):
    hdr = "export ORACLE_HOME='%s'; export ORACLE_SID='%s'; export PATH=\"$ORACLE_HOME/bin:$PATH\"; sqlplus -s / as sysdba <<'__SQL__'\n" % (oracle_home, sid)
    cmd = hdr + SQL_BODY + "\n__SQL__"
    return ctx.run(["/bin/sh", "-c", cmd], mutates=False)

def _parse_output(stdout):
    for line in stdout.splitlines():
        s = line.strip()
        if not s or s.startswith("ORA-") or s.startswith("SP2-") or s.startswith("ERROR"):
            continue
        parts = s.split()
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            return {"count": int(parts[0]), "limit": int(parts[1])}
    return None

def _first_ora_error(stdout):
    for line in stdout.splitlines():
        s = line.strip()
        if s.startswith("ORA-") or s.startswith("SP2-"):
            return s
    return None

def _find_oracle_home(instances, item):
    for inst in instances:
        if inst["sid"] == item:
            return inst["oracle_home"]
    return None

def main(ctx, params):
    if params.get("_discover"):
        instances = _find_oratab_instances(ctx)
        discovery = []
        for inst in instances:
            res = _run_sqlplus(ctx, inst["sid"], inst["oracle_home"])
            if res.rc != 0:
                continue
            data = _parse_output(res.stdout)
            if data == None:
                continue
            discovery.append({
                "item": inst["sid"],
                "params": {"warn": 70.0, "crit": 90.0},
                "metrics": ["processes", "processes_pct"],
            })
        return {
            "changed": False,
            "msg": "discovered %d oracle instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    warn = params.get("warn", 70.0)
    crit = params.get("crit", 90.0)

    oracle_home = params.get("oracle_home")
    if oracle_home == None:
        instances = _find_oratab_instances(ctx)
        oracle_home = _find_oracle_home(instances, item)

    if oracle_home == None:
        return {
            "changed": False,
            "msg": "Oracle instance %s not found in oratab" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "not in oratab"},
        }

    res = _run_sqlplus(ctx, item, oracle_home)

    ora_err = _first_ora_error(res.stdout)
    if ora_err != None:
        return {
            "changed": False,
            "msg": "ORA error on %s: %s" % (item, ora_err),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ora_err},
        }

    if res.rc != 0:
        detail = res.stderr.strip()
        if not detail:
            detail = "sqlplus exited with rc %d" % res.rc
        return {
            "changed": False,
            "msg": "sqlplus failed for %s: %s" % (item, detail),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": detail},
        }

    data = _parse_output(res.stdout)
    if data == None:
        return {
            "changed": False,
            "msg": "No process data for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    count = data["count"]
    limit = data["limit"]

    if limit == 0:
        return {
            "changed": False,
            "msg": "Process limit is 0 for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "limit is 0"},
        }

    pct = float(count) / float(limit) * 100.0
    state = "CRIT" if pct >= crit else ("WARN" if pct >= warn else "OK")
    msg = "%d of %d processes used (%f%%)" % (count, limit, pct)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"processes": count, "processes_pct": pct},
            "details": "",
        },
    }