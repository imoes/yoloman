def main(ctx, params):
    if params.get("_discover"):
        oracle_home = _find_oracle_home(ctx)
        if oracle_home == None:
            return {"changed": False, "msg": "no oracle installation found",
                    "data": {"discovery": []}}
        sql = "SELECT upper(sid) AS instance_name, sid, serial#, machine, process, osuser, program, last_call_et, sql_id FROM v$session WHERE status='ACTIVE' AND last_call_et > 0"
        res = ctx.run(["sqlplus", "-s", "/ as sysdba", "@-"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "sqlplus not available",
                    "data": {"discovery": []}}
        lines = _parse_table(res.stdout)
        if len(lines) == 0:
            return {"changed": False, "msg": "no long active sessions found",
                    "data": {"discovery": []}}
        discovery = []
        for line in lines[1:]:
            if len(line) < 9:
                continue
            instance = line[0]
            found = False
            for d in discovery:
                if d["item"] == instance:
                    found = True
                    break
            if not found:
                discovery.append({"item": instance,
                                  "params": {"levels": [500, 1000]},
                                  "metrics": ["count"]})
        return {"changed": False,
                "msg": "discovered %d oracle long active session services" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    sql = "SELECT sid, serial#, machine, process, osuser, program, last_call_et, sql_id FROM v$session WHERE status='ACTIVE' AND last_call_et > 0 AND upper(sid)='%s'" % item.upper()
    res = ctx.run(["sqlplus", "-s", "/ as sysdba", "@-"], mutates=False)
    if res.rc == 127:
        return {"changed": False,
                "msg": "sqlplus not available on host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = _parse_table(res.stdout)
    if len(lines) <= 1:
        return {"changed": False,
                "msg": "no info from database. Check ORA %s Instance" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sessioncount = 0
    longoutput = None
    for line in lines[1:]:
        if len(line) < 8:
            continue
        sid, serial, machine, process, osuser, program, last_call_el, sql_id = line[:8]
        if str(sid).upper() != item.upper():
            continue
        sessioncount += 1
        longoutput = "Session (sid,serial,proc) %s %s %s active for %s from %s osuser %s program %s sql_id %s" % (sid, serial, process,
                          _render_timespan(int(last_call_el) if last_call_el.isdigit() else 0),
                          machine, osuser, program, sql_id)
    levels = params.get("levels", (500, 1000))
    warn = levels[0] if len(levels) > 0 else 500
    crit = levels[1] if len(levels) > 1 else 1000
    state = "CRIT" if sessioncount >= crit else ("WARN" if sessioncount >= warn else "OK")
    msg = "sessions: %d" % sessioncount
    if longoutput:
        msg = longoutput
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"count": sessioncount}, "details": ""}}

def _find_oracle_home(ctx):
    res = ctx.run(["which", "sqlplus"], mutates=False)
    if res.rc == 0:
        return "/usr/bin"
    res = ctx.run(["sqlplus", "-v"], mutates=False)
    if res.rc == 127:
        return None
    return "/usr/bin"

def _parse_table(out):
    lines = []
    for raw in out.splitlines():
        s = raw.strip()
        if len(s) == 0 or s.startswith("-") or s.startswith("SQL>"):
            continue
        lines.append(s.split("|"))
    return lines

def _render_timespan(sec):
    if sec == None or sec <= 0:
        return "0s"
    s = int(sec)
    d = s // 86400
    s = s % 86400
    h = s // 3600
    s = s % 3600
    m = s // 60
    s = s % 60
    parts = []
    if d > 0:
        parts.append("%dd" % d)
    if h > 0:
        parts.append("%dh" % h)
    if m > 0:
        parts.append("%dm" % m)
    parts.append("%ds" % s)
    return " ".join(parts)