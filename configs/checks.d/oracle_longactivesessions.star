SQL_SESSIONS = (
    "SET PAGESIZE 0\n" +
    "SET FEEDBACK OFF\n" +
    "SET HEADING OFF\n" +
    "SET TRIMSPOOL ON\n" +
    "SET LINESIZE 1000\n" +
    "SELECT sid||'|'||serial#||'|'||machine||'|'||process||'|'||osuser" +
    "||'|'||program||'|'||last_call_et||'|'||NVL(sql_id,'')" +
    " FROM v$session WHERE status='ACTIVE'" +
    " AND username IS NOT NULL AND last_call_et > 0;\n" +
    "EXIT;\n"
)

def _oratab_entries(ctx):
    entries = []
    if not ctx.file_exists("/etc/oratab"):
        return entries
    content = ctx.file_read("/etc/oratab")
    for line in content.splitlines():
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            continue
        parts = stripped.split(":")
        if len(parts) < 2:
            continue
        sid = parts[0].strip()
        oh = parts[1].strip()
        if sid == "" or sid == "*" or oh == "" or oh == "N/A":
            continue
        entries.append({"sid": sid, "oracle_home": oh})
    return entries

def _query_sessions(ctx, sid, oracle_home):
    cmd_str = (
        "ORACLE_SID=" + sid +
        " ORACLE_HOME=" + oracle_home +
        " PATH=" + oracle_home + "/bin:$PATH " +
        oracle_home + "/bin/sqlplus -s / as sysdba <<'SQL_END'\n" +
        SQL_SESSIONS +
        "SQL_END\n"
    )
    return ctx.run(["bash", "-c", cmd_str], mutates=False)

def _parse_sessions(stdout):
    sessions = []
    for line in stdout.splitlines():
        s = line.strip()
        if s == "":
            continue
        if s.startswith("SP2-") or s.startswith("ORA-") or s.startswith("ERROR"):
            continue
        parts = s.split("|")
        if len(parts) < 7:
            continue
        sessions.append(parts)
    return sessions

def _fmt_timespan(secs):
    s = int(secs)
    h = s // 3600
    m = (s % 3600) // 60
    sec = s % 60
    if h > 0:
        return "%d h %d m %d s" % (h, m, sec)
    if m > 0:
        return "%d m %d s" % (m, sec)
    return "%d s" % sec

def main(ctx, params):
    warn = params.get("warn", 500)
    crit = params.get("crit", 1000)

    if params.get("_discover"):
        entries = _oratab_entries(ctx)
        discovery = []
        for e in entries:
            discovery.append({
                "item": e["sid"],
                "params": {"warn": 500, "crit": 1000, "oracle_home": e["oracle_home"]},
                "metrics": ["count"],
            })
        return {
            "changed": False,
            "msg": "discovered %d Oracle instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    oracle_home = params.get("oracle_home", "")

    if oracle_home == "":
        entries = _oratab_entries(ctx)
        for e in entries:
            if e["sid"] == item:
                oracle_home = e["oracle_home"]
                break

    if oracle_home == "":
        return {
            "changed": False,
            "msg": "oracle_home not found for instance: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = _query_sessions(ctx, item, oracle_home)

    for line in res.stdout.splitlines():
        s = line.strip()
        if s.startswith("ORA-"):
            return {
                "changed": False,
                "msg": "Oracle error on " + item + ": " + s,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": s},
            }

    if res.rc != 0:
        err = res.stderr.strip()
        if err == "":
            err = res.stdout.strip()
        return {
            "changed": False,
            "msg": "sqlplus failed for " + item + " (rc=%d): " % res.rc + err,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": err},
        }

    sessions = _parse_sessions(res.stdout)
    session_count = len(sessions)

    details_parts = []
    for parts in sessions:
        sidnr   = parts[0].strip()
        serial  = parts[1].strip()
        machine = parts[2].strip()
        process = parts[3].strip()
        osuser  = parts[4].strip()
        program = parts[5].strip()
        raw_el  = parts[6].strip()
        sql_id  = parts[7].strip() if len(parts) > 7 else ""
        elapsed = _fmt_timespan(int(raw_el) if raw_el.isdigit() else 0)
        details_parts.append(
            "Session (sid,serial,proc) %s %s %s active for %s from %s osuser %s program %s sql_id %s" % (
                sidnr, serial, process, elapsed, machine, osuser, program, sql_id
            )
        )

    state = "CRIT" if session_count >= crit else ("WARN" if session_count >= warn else "OK")
    msg = "Long active sessions: %d" % session_count
    if state != "OK":
        msg += " (warn=%d, crit=%d)" % (warn, crit)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"count": session_count},
            "details": "\n".join(details_parts),
        },
    }