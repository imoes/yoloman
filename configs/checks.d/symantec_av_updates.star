DEFAULT_WARN = 259200   # 3 * 24 * 3600 = 3 days
DEFAULT_CRIT = 345600   # 4 * 24 * 3600 = 4 days

DEF_DIRS = [
    "/opt/Symantec/symantec_antivirus/definitions",
    "/opt/Symantec/sdcss/etc/def",
    "/opt/Symantec/sep/definitions",
    "/opt/symantec/definitions",
    "/var/lib/symantec/definitions",
]

def main(ctx, params):
    if params.get("_discover"):
        for path in DEF_DIRS:
            if ctx.stat(path) != None:
                return {
                    "changed": False,
                    "msg": "discovered AV Update Status",
                    "data": {"discovery": [{
                        "item": "",
                        "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                        "metrics": ["age_seconds"],
                    }]},
                }
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)

    now_res = ctx.run(["date", "+%s"], mutates=False)
    if now_res.rc != 0 or not now_res.stdout.strip().isdigit():
        return {
            "changed": False,
            "msg": "cannot get current time",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    now = int(now_res.stdout.strip())

    def_path = None
    for path in DEF_DIRS:
        if ctx.stat(path) != None:
            def_path = path
            break

    if def_path == None:
        return {
            "changed": False,
            "msg": "Symantec AV definitions not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    find_res = ctx.run(
        ["find", def_path, "-maxdepth", "2", "-type", "f", "-printf", "%T@\n"],
        mutates=False,
        ok_codes=[0, 1],
    )

    newest = 0
    if find_res.rc == 0 and find_res.stdout.strip():
        for line in find_res.stdout.splitlines():
            ts_str = line.split(".")[0].strip()
            if ts_str.isdigit():
                ts = int(ts_str)
                if ts > newest:
                    newest = ts

    if newest == 0:
        stat_res = ctx.run(["stat", "-c", "%Y", def_path], mutates=False, ok_codes=[0, 1])
        if stat_res.rc == 0 and stat_res.stdout.strip().isdigit():
            newest = int(stat_res.stdout.strip())

    if newest == 0:
        return {
            "changed": False,
            "msg": "cannot determine definition update time",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    age = now - newest
    if age < 0:
        age = 0

    state = "CRIT" if age >= crit else ("WARN" if age >= warn else "OK")

    days = age // 86400
    hours = (age % 86400) // 3600
    mins = (age % 3600) // 60
    age_str = "%d days %d hours %d min" % (days, hours, mins)

    return {
        "changed": False,
        "msg": "Time since last update: " + age_str,
        "data": {
            "state": state,
            "metrics": {"age_seconds": age},
            "details": "path: " + def_path,
        },
    }