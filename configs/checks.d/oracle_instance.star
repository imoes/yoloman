OPEN_MODES = ["OPEN", "READ ONLY", "READ WRITE"]

LOGINS_MAP = {"RESTRICTED": "logins"}
ARCHIVELOG_MAP = {"ARCHIVELOG": "archivelog", "NOARCHIVELOG": "noarchivelog"}
FORCELOGGING_MAP = {"YES": "forcelogging", "NO": "noforcelogging"}

STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def _state_name(code):
    s = STATE_NAMES.get(code)
    return s if s != None else "UNKNOWN"


def _worst(s1, s2):
    return s2 if STATE_ORDER.get(s2, 0) > STATE_ORDER.get(s1, 0) else s1


def _assess(label, value, p, key_map):
    key = key_map.get(value.upper())
    if key == None:
        return ("OK", "%s %s" % (label, value.lower()))
    return (_state_name(p.get(key, 0)), "%s %s" % (label, value.lower()))


def _sqlplus(ctx, sid, oracle_home):
    sql = "\n".join([
        "SET HEADING OFF",
        "SET LINESIZE 2000",
        "SET PAGESIZE 0",
        "SET FEEDBACK OFF",
        "SET TRIMSPOOL ON",
        "SELECT i.instance_name||'|'||i.version||'|'||i.status||'|'||i.logins||'|'||",
        "       NVL(i.archiver,'UNKNOWN')||'|'||",
        "       FLOOR((SYSDATE - i.startup_time)*86400)||'|'||",
        "       d.log_mode||'|'||d.database_role||'|'||d.force_logging||'|'||d.name||'|'||",
        "       NVL(i.host_name,'')",
        "FROM v$instance i, v$database d;",
        "EXIT;",
    ])
    if oracle_home != None and oracle_home != "":
        env = ("ORACLE_HOME=" + oracle_home + " ORACLE_SID=" + sid +
               " PATH=" + oracle_home + "/bin:$PATH")
    else:
        env = "ORACLE_SID=" + sid
    bash_cmd = env + " sqlplus -S / as sysdba <<'SQLEOF'\n" + sql + "\nSQLEOF"
    return ctx.run(["bash", "-c", bash_cmd], mutates=False, ok_codes=[0, 1, 2])


def _parse_inst(stdout):
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) < 10:
            continue
        sid = parts[0].strip()
        if not sid or sid.startswith("ORA-") or sid.startswith("ERROR"):
            continue
        version = parts[1].strip()
        if not version:
            continue
        return {
            "sid": sid,
            "version": version,
            "openmode": parts[2].strip(),
            "logins": parts[3].strip(),
            "archiver": parts[4].strip(),
            "up_seconds": parts[5].strip(),
            "log_mode": parts[6].strip(),
            "database_role": parts[7].strip(),
            "force_logging": parts[8].strip(),
            "name": parts[9].strip(),
            "host_name": parts[10].strip() if len(parts) > 10 else "",
        }
    return None


def main(ctx, params):
    oracle_home = params.get("oracle_home")

    # --- DISCOVERY ---
    if params.get("_discover"):
        sids = []
        if ctx.file_exists("/etc/oratab"):
            for line in ctx.file_read("/etc/oratab").splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(":")
                if len(parts) < 2:
                    continue
                sid = parts[0].strip()
                if sid and sid != "*":
                    sids.append(sid)
        items = [
            {
                "item": sid,
                "params": {
                    "logins": 2,
                    "noforcelogging": 1,
                    "noarchivelog": 1,
                    "primarynotopen": 2,
                    "archivelog": 0,
                    "forcelogging": 0,
                },
                "metrics": [],
            }
            for sid in sids
        ]
        return {
            "changed": False,
            "msg": "discovered %d Oracle instances" % len(items),
            "data": {"discovery": items},
        }

    # --- CHECK ---
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    p = {
        "logins": params.get("logins", 2),
        "noforcelogging": params.get("noforcelogging", 1),
        "noarchivelog": params.get("noarchivelog", 1),
        "primarynotopen": params.get("primarynotopen", 2),
        "archivelog": params.get("archivelog", 0),
        "forcelogging": params.get("forcelogging", 0),
    }

    res = _sqlplus(ctx, item, oracle_home)

    ora_err = ""
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("ORA-"):
            ora_err = stripped
            break

    inst = _parse_inst(res.stdout)
    if inst == None:
        msg = ora_err if ora_err else "Database or necessary processes not running or login failed"
        return {
            "changed": False,
            "msg": msg,
            "data": {"state": "CRIT", "metrics": {}, "details": res.stdout},
        }

    msgs = []
    overall = "OK"

    msgs.append("Database Name %s" % inst["name"])

    role = inst["database_role"]
    openmode = inst["openmode"]

    if role == "PRIMARY" and openmode not in OPEN_MODES:
        s = _state_name(p["primarynotopen"])
        overall = _worst(overall, s)
        suffix = " (allowed by rule)" if s == "OK" else ""
        msgs.append("Status %s%s" % (openmode, suffix))
    else:
        msgs.append("Status %s" % openmode)

    msgs.append("Role %s" % role)
    msgs.append("Version %s" % inst["version"])

    host_name = inst["host_name"]
    if host_name:
        msgs.append("Running on: %s" % host_name)

    if role != "ASM":
        if openmode in OPEN_MODES:
            (s, m) = _assess("Logins", inst["logins"], p, LOGINS_MAP)
            overall = _worst(overall, s)
            msgs.append(m)

        sid = inst["sid"]
        name = inst["name"]
        if sid != "_MGMTDB" and name != "-MGMTDB":
            log_mode = inst["log_mode"]
            if log_mode:
                (s, m) = _assess("Log Mode", log_mode, p, ARCHIVELOG_MAP)
                overall = _worst(overall, s)
                msgs.append(m)

                if log_mode == "ARCHIVELOG":
                    archiver = inst["archiver"]
                    if archiver and archiver != "STARTED":
                        overall = _worst(overall, "CRIT")
                        msgs.append("Archiver %s" % archiver.lower())

                    force_log = inst["force_logging"]
                    if force_log:
                        (s, m) = _assess("Force Logging", force_log, p, FORCELOGGING_MAP)
                        overall = _worst(overall, s)
                        msgs.append(m)

    metrics = {}
    up_str = inst["up_seconds"]
    if up_str and up_str.isdigit():
        metrics["uptime"] = int(up_str)

    return {
        "changed": False,
        "msg": ", ".join(msgs),
        "data": {
            "state": overall,
            "metrics": metrics,
            "details": "",
        },
    }