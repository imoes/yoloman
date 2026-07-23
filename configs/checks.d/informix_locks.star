INFORMIX_DIR_DEFAULT = "/opt/IBM/informix"

def _parse_lock_count(stdout):
    for line in stdout.splitlines():
        stripped = line.strip()
        if "active," in stripped and "total," in stripped:
            parts = stripped.split()
            if len(parts) >= 1 and parts[0].isdigit():
                return int(parts[0])
    return -1

def main(ctx, params):
    informix_dir = params.get("informix_dir", INFORMIX_DIR_DEFAULT)
    onstat_bin = informix_dir + "/bin/onstat"

    if params.get("_discover"):
        search_paths = [
            informix_dir + "/etc/sqlhosts",
            "/etc/informix/sqlhosts",
        ]
        content = ""
        for p in search_paths:
            if ctx.file_exists(p):
                content = ctx.file_read(p)
                break

        if not content:
            return {
                "changed": False,
                "msg": "discovered 0 instances",
                "data": {"discovery": []},
            }

        instances = []
        seen = {}
        for line in content.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = stripped.split()
            if len(parts) >= 1:
                name = parts[0]
                if name not in seen:
                    seen[name] = True
                    instances.append({
                        "item": name,
                        "params": {"levels": [70, 80], "informix_dir": informix_dir},
                        "metrics": ["locks"],
                    })

        return {
            "changed": False,
            "msg": "discovered %d instances" % len(instances),
            "data": {"discovery": instances},
        }

    item = params.get("item", "")
    levels = params.get("levels", [70, 80])
    warn = levels[0]
    crit = levels[1]

    if not ctx.file_exists(onstat_bin):
        return {
            "changed": False,
            "msg": "onstat not found at %s" % onstat_bin,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(
        ["env",
         "INFORMIXDIR=" + informix_dir,
         "INFORMIXSERVER=" + item,
         "ONCONFIG=onconfig." + item,
         onstat_bin, "-k"],
        mutates=False,
        ok_codes=[0, 1, 2, 255],
    )

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "onstat -k failed (rc=%d) for %s" % (res.rc, item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    locks = _parse_lock_count(res.stdout)

    if locks < 0:
        return {
            "changed": False,
            "msg": "could not parse lock count for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stdout},
        }

    state = "CRIT" if locks >= crit else ("WARN" if locks >= warn else "OK")

    return {
        "changed": False,
        "msg": "Type: active, Locks: %d" % locks,
        "data": {"state": state, "metrics": {"locks": locks}, "details": ""},
    }