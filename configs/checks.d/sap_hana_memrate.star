def _all_digits(s):
    if len(s) == 0:
        return False
    for i in range(len(s)):
        if s[i] < "0" or s[i] > "9":
            return False
    return True

def _parse_row(line):
    vals = []
    for p in line.strip().split(","):
        vals.append(p.strip().strip('"'))
    return vals

def _find_instances(ctx):
    if not ctx.file_exists("/usr/sap"):
        return []
    res = ctx.run(
        ["find", "/usr/sap", "-mindepth", "2", "-maxdepth", "2", "-type", "d"],
        mutates=False, ok_codes=[0, 1, 2]
    )
    instances = []
    seen = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        segs = line.split("/")
        if len(segs) < 5:
            continue
        sid = segs[3]
        hdb = segs[4]
        if not hdb.startswith("HDB"):
            continue
        nr = hdb[3:]
        if len(nr) == 2 and _all_digits(nr):
            k = sid + "/" + nr
            if k not in seen:
                seen[k] = True
                instances.append({"sid": sid, "nr": nr})
    return instances

def _run_hdbsql(ctx, sid, nr, user, password, sql):
    port = "3" + nr + "15"
    exe = "/usr/sap/" + sid + "/HDB" + nr + "/exe/hdbsql"
    if ctx.file_exists(exe):
        return ctx.run(
            [exe, "-n", "localhost:" + port, "-u", user, "-p", password, "-a", "-x", sql],
            mutates=False, ok_codes=[0, 1, 2]
        )
    sid_adm = sid.lower() + "adm"
    shell_cmd = ("hdbsql -n localhost:" + port +
                 " -u " + user + " -p " + password + " -a -x '" + sql + "'")
    return ctx.run(["su", "-", sid_adm, "-c", shell_cmd], mutates=False, ok_codes=[0, 1, 2])

MEM_SQL = "SELECT USED_PHYSICAL_MEMORY, FREE_PHYSICAL_MEMORY FROM SYS.M_HOST_RESOURCE_UTILIZATION WHERE HOST = CURRENT_HOST"

def main(ctx, params):
    user = params.get("user", "SYSTEM")
    password = params.get("password", "")
    warn = params.get("warn", 70.0)
    crit = params.get("crit", 80.0)

    if params.get("_discover"):
        instances = _find_instances(ctx)
        discovery = []
        for inst in instances:
            item = inst["sid"] + " HDB" + inst["nr"]
            discovery.append({
                "item": item,
                "params": {"warn": 70.0, "crit": 80.0},
                "metrics": ["memory_used"],
            })
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    item_parts = item.split()
    if len(item_parts) < 2 or not item_parts[1].startswith("HDB"):
        return {
            "changed": False,
            "msg": "invalid item format (expected '<SID> HDB<NR>'): " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sid = item_parts[0]
    nr_raw = item_parts[1][3:]
    if not _all_digits(nr_raw):
        return {
            "changed": False,
            "msg": "non-numeric instance number in item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    nr = nr_raw if len(nr_raw) == 2 else ("0" + nr_raw if len(nr_raw) == 1 else nr_raw)

    res = _run_hdbsql(ctx, sid, nr, user, password, MEM_SQL)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "login into database failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    data_lines = []
    for l in res.stdout.splitlines():
        s = l.strip()
        if s and not s.startswith("USED") and "row" not in s.lower():
            data_lines.append(s)

    if not data_lines:
        return {
            "changed": False,
            "msg": "no memory data returned for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    vals = _parse_row(data_lines[0])
    if len(vals) < 2 or not _all_digits(vals[0]) or not _all_digits(vals[1]):
        return {
            "changed": False,
            "msg": "cannot parse memory output: " + data_lines[0],
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used = int(vals[0])
    free = int(vals[1])
    total = used + free

    if total == 0:
        return {
            "changed": False,
            "msg": "total memory is zero for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    perc = float(used) / float(total) * 100.0
    state = "CRIT" if perc >= crit else ("WARN" if perc >= warn else "OK")
    used_gib = float(used) / 1073741824.0
    total_gib = float(total) / 1073741824.0
    msg = "Usage: %f%% - %f/%f GiB" % (perc, used_gib, total_gib)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"memory_used": used},
            "details": "",
        },
    }