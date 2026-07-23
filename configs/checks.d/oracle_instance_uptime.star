# oracle_instance_uptime: queries V$INSTANCE for uptime via sqlplus '/ as sysdba'

_SQL = """SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF LINESIZE 200 TRIMOUT ON
SELECT ROUND((SYSDATE-STARTUP_TIME)*86400) FROM V$INSTANCE;
EXIT;"""

def _parse_oratab(ctx):
    entries = []
    if not ctx.file_exists("/etc/oratab"):
        return entries
    for line in ctx.file_read("/etc/oratab").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(":")
        if len(parts) >= 2 and parts[0].strip() and parts[0].strip() != "*":
            entries.append({"sid": parts[0].strip(), "home": parts[1].strip()})
    return entries

def _active_sids(ctx):
    res = ctx.run(["pgrep", "-l", "ora_pmon"], mutates=False, ok_codes=[0, 1])
    sids = []
    if res.rc != 0:
        return sids
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and "ora_pmon_" in parts[1]:
            sid = parts[1].split("ora_pmon_")[1]
            if sid and not sid.startswith("+"):
                sids.append(sid)
    return sids

def _oracle_home(ctx, sid):
    for e in _parse_oratab(ctx):
        if e["sid"] == sid:
            return e["home"]
    res = ctx.run(["pgrep", "-l", "ora_pmon_" + sid], mutates=False, ok_codes=[0, 1])
    if res.rc != 0 or not res.stdout.strip():
        return None
    pid = res.stdout.strip().split()[0]
    env_file = "/proc/%s/environ" % pid
    if not ctx.file_exists(env_file):
        return None
    for part in ctx.file_read(env_file).split("\x00"):
        if part.startswith("ORACLE_HOME="):
            return part[12:]
    return None

def _query_uptime(ctx, sid, oracle_home):
    sqlplus = oracle_home + "/bin/sqlplus"
    if not ctx.file_exists(sqlplus):
        return None
    cmd = "ORACLE_SID=%s ORACLE_HOME=%s %s -s '/ as sysdba' << 'EOSQL'\n%s\nEOSQL" % (
        sid, oracle_home, sqlplus, _SQL
    )
    res = ctx.run(["bash", "-c", cmd], mutates=False, ok_codes=[0, 1])
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        candidate = line.lstrip("-")
        if candidate and candidate.isdigit():
            return int(line)
    return None

def _fmt_uptime(s):
    d = s // 86400
    s = s % 86400
    h = s // 3600
    s = s % 3600
    m = s // 60
    s = s % 60
    if d > 0:
        return "%dd %dh %dm %ds" % (d, h, m, s)
    if h > 0:
        return "%dh %dm %ds" % (h, m, s)
    if m > 0:
        return "%dm %ds" % (m, s)
    return "%ds" % s

def main(ctx, params):
    if params.get("_discover"):
        found = []
        for sid in _active_sids(ctx):
            home = _oracle_home(ctx, sid)
            if home == None:
                continue
            up = _query_uptime(ctx, sid, home)
            if up != None and up != -1:
                found.append({"item": sid, "params": {}, "metrics": ["uptime"]})
        return {
            "changed": False,
            "msg": "discovered %d oracle instances with uptime" % len(found),
            "data": {"discovery": found},
        }

    item = params.get("item", "")
    home = params.get("oracle_home")
    if home == None:
        home = _oracle_home(ctx, item)
    if home == None:
        return {
            "changed": False,
            "msg": "Login into database failed: oracle_home not found for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    up = _query_uptime(ctx, item, home)
    if up == None:
        return {
            "changed": False,
            "msg": "Login into database failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if up < 0:
        return {
            "changed": False,
            "msg": "Uptime: invalid negative value (%ds)" % up,
            "data": {"state": "WARN", "metrics": {"uptime": up}, "details": ""},
        }

    state = "OK"
    min_levels = params.get("min")
    if min_levels != None:
        warn_min = min_levels[0]
        crit_min = min_levels[1]
        if up < crit_min:
            state = "CRIT"
        elif up < warn_min:
            state = "WARN"

    max_levels = params.get("max")
    if max_levels != None:
        warn_max = max_levels[0]
        crit_max = max_levels[1]
        if up >= crit_max:
            state = "CRIT"
        elif (up >= warn_max) and state != "CRIT":
            state = "WARN"

    return {
        "changed": False,
        "msg": "Uptime: " + _fmt_uptime(up),
        "data": {
            "state": state,
            "metrics": {"uptime": up},
            "details": "",
        },
    }