INFORMIX_SQL_DBS = "SELECT TRIM(name) FROM sysdatabases WHERE name NOT LIKE 'sys%' ORDER BY name;"
INFORMIX_SQL_EXT = "SELECT FIRST 25 TRIM(tabname), nextns, nrows FROM systables WHERE tabtype='T' ORDER BY nextns DESC;"

def _is_digits(s):
    if not s:
        return False
    for c in s:
        if c not in "0123456789":
            return False
    return True

def _dbaccess(ctx, informixdir, instance, db, sql):
    env = (
        "INFORMIXDIR=" + informixdir +
        " INFORMIXSERVER=" + instance +
        " PATH=" + informixdir + "/bin:$PATH"
    )
    script = env + " dbaccess " + db + " - 2>/dev/null <<'ENDSQL'\n" + sql + "\nENDSQL"
    return ctx.run(["bash", "-c", script], mutates=False, ok_codes=[0, 1, 2, 25, 100, 126, 127, 255])

def _parse_col0(stdout):
    rows = []
    header_done = False
    for line in stdout.splitlines():
        s = line.strip()
        if not s:
            continue
        if "row(s) retrieved" in s or "rows retrieved" in s:
            break
        if not header_done:
            header_done = True
            continue
        parts = s.split()
        if parts:
            rows.append(parts[0])
    return rows

def _parse_extents(stdout):
    rows = []
    header_done = False
    for line in stdout.splitlines():
        s = line.strip()
        if not s:
            continue
        if "row(s) retrieved" in s or "rows retrieved" in s:
            break
        if not header_done:
            header_done = True
            continue
        parts = s.split()
        if len(parts) >= 2 and _is_digits(parts[1]):
            rows.append({
                "tab": parts[0],
                "extents": int(parts[1]),
                "nrows": int(parts[2]) if len(parts) >= 3 and _is_digits(parts[2]) else 0,
            })
    return rows

def main(ctx, params):
    informixdir = params.get("informixdir", "/opt/informix")
    levels = params.get("levels", (40, 70))
    warn = levels[0]
    crit = levels[1]

    if params.get("_discover"):
        ps = ctx.run(
            ["bash", "-c", "ps -eo args 2>/dev/null | grep oninit | grep -v grep"],
            mutates=False, ok_codes=[0, 1]
        )
        seen = {}
        for line in ps.stdout.splitlines():
            parts = line.strip().split()
            for i in range(len(parts)):
                if parts[i] == "-s" and i + 1 < len(parts):
                    seen[parts[i + 1]] = True
        env_r = ctx.run(["bash", "-c", "echo ${INFORMIXSERVER:-}"], mutates=False, ok_codes=[0])
        env_inst = env_r.stdout.strip()
        if env_inst:
            seen[env_inst] = True
        disc = [
            {"item": inst, "params": {"levels": (40, 70)}, "metrics": ["max_extents"]}
            for inst in seen
        ]
        return {
            "changed": False,
            "msg": "discovered %d Informix instances" % len(disc),
            "data": {"discovery": disc},
        }

    item = params.get("item", "")
    dbaccess_bin = informixdir + "/bin/dbaccess"
    if not ctx.file_exists(dbaccess_bin):
        return {
            "changed": False,
            "msg": "dbaccess not found at " + dbaccess_bin,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    dbs = _parse_col0(_dbaccess(ctx, informixdir, item, "sysmaster", INFORMIX_SQL_DBS).stdout)
    if not dbs:
        return {
            "changed": False,
            "msg": "no databases found for instance " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    max_extents = -1
    details = []
    for db in dbs:
        for row in _parse_extents(_dbaccess(ctx, informixdir, item, db, INFORMIX_SQL_EXT).stdout):
            if row["extents"] > max_extents:
                max_extents = row["extents"]
            details.append("[%s/%s] Extents: %d, Rows: %d" % (db, row["tab"], row["extents"], row["nrows"]))

    if max_extents < 0:
        return {
            "changed": False,
            "msg": "no table extent data for instance " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "CRIT" if max_extents >= crit else ("WARN" if max_extents >= warn else "OK")
    return {
        "changed": False,
        "msg": "Maximal extents: %d" % max_extents,
        "data": {
            "state": state,
            "metrics": {"max_extents": max_extents},
            "details": "\n".join(details),
        },
    }