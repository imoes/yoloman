def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["sqlplus", "-s", "/nolog"], mutates=False)
        if res.rc != 0:
            if res.rc == 127:
                return {"changed": False, "msg": "sqlplus not installed", "data": {"discovery": []}}
            return {"changed": False, "msg": "sqlplus probe failed: " + str(res.stderr), "data": {"discovery": []}}

        script = _build_session_script(None)
        res = ctx.run(["sqlplus", "-s", "/nolog"], mutates=False, stdin=script)
        if res.rc != 0:
            return {"changed": False, "msg": "sqlplus query failed: " + str(res.stderr), "data": {"discovery": []}}

        discovery = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            sid = parts[0]
            discovery.append({
                "item": sid,
                "params": {"sessions_abs": (150, 300)},
                "metrics": ["sessions"],
            })
        return {"changed": False, "msg": "discovered " + str(len(discovery)) + " instances",
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no Oracle instance item given",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["sqlplus", "-s", "/nolog"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "sqlplus not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    script = _build_session_script(item)
    res = ctx.run(["sqlplus", "-s", "/nolog"], mutates=False, stdin=script)
    if res.rc != 0:
        return {"changed": False, "msg": "sqlplus query failed: " + str(res.stderr),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sessions = 0
    sessions_max = None
    found = False
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == item:
            found = True
            sessions = int(parts[1]) if parts[1].isdigit() else 0
            break

    if not found:
        return {"changed": False, "msg": "Login into database failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sp_script = _build_max_script(item)
    sp_res = ctx.run(["sqlplus", "-s", "/nolog"], mutates=False, stdin=sp_script)
    if sp_res.rc == 0:
        for line in sp_res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 1 and parts[0].isdigit():
                sessions_max = int(parts[0])
                break

    levels_abs = params.get("sessions_abs", (150, 300))
    warn_abs = levels_abs[0] if type(levels_abs) == "list" and len(levels_abs) > 0 else 150
    crit_abs = levels_abs[1] if type(levels_abs) == "list" and len(levels_abs) > 1 else 300

    state = "CRIT" if sessions >= crit_abs else ("WARN" if sessions >= warn_abs else "OK")
    metrics = {"sessions": sessions}

    details = "Sessions: " + str(sessions)
    if sessions_max != None:
        sessions_perc = 100.0 * sessions / sessions_max
        metrics["sessions_perc"] = sessions_perc
        levels_perc = params.get("sessions_perc")
        if levels_perc != None:
            warn_perc = levels_perc[0] if type(levels_perc) == "list" and len(levels_perc) > 0 else 80
            crit_perc = levels_perc[1] if type(levels_perc) == "list" and len(levels_perc) > 1 else 90
            if sessions_perc >= crit_perc:
                state = "CRIT"
            elif sessions_perc >= warn_perc:
                state = "WARN"
        details += ", Max processes: " + str(sessions_max) + " (" + _fmt_percent(sessions_perc) + ")"

    max_str = str(sessions_max) if sessions_max != None else "max n/a"
    return {"changed": False,
            "msg": "Sessions: " + str(sessions) + " (" + max_str + ")",
            "data": {"state": state, "metrics": metrics, "details": details}}


def _build_session_script(item):
    base = "set heading off\n" + \
        "set feedback off\n" + \
        "set pagesize 0\n" + \
        "set trimspool on\n" + \
        "select sys_context('USERENV','DB_NAME')||' '||count(*)\n" + \
        "from v$session\n"
    if item != None:
        base = base + "where sys_context('USERENV','DB_NAME')='" + item + "'\n"
    base = base + ";\nexit\n"
    return base


def _build_max_script(item):
    base = "set heading off\n" + \
        "set feedback off\n" + \
        "set pagesize 0\n" + \
        "set trimspool on\n" + \
        "select count(*) from v$resource_limit\n" + \
        "where resource_name='processes'\n" + \
        "and sys_context('USERENV','DB_NAME')='" + item + "'\n" + \
        ";\nexit\n"
    return base


def _fmt_percent(p):
    s = "%f" % p
    return s + "%"