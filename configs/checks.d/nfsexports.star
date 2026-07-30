def _get_exports(stdout):
    exports = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("/"):
            parts = stripped.split()
            if len(parts) >= 1:
                exports.append(parts[0])
    return exports

def main(ctx, params):
    res = ctx.run(["showmount", "-e", "localhost"], mutates=False, ok_codes=[0, 1, 127])

    if params.get("_discover"):
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 exports", "data": {"discovery": []}}
        exports = _get_exports(res.stdout)
        items = [{"item": e, "params": {}, "metrics": []} for e in exports]
        return {
            "changed": False,
            "msg": "discovered %d exports" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")

    if res.rc == 127:
        return {
            "changed": False,
            "msg": "showmount not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "showmount error: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr.strip()},
        }

    exports = _get_exports(res.stdout)

    if len(exports) == 0:
        return {
            "changed": False,
            "msg": "exports defined but no exports found in export list. Daemons might not be working",
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    for e in exports:
        if e == item:
            return {
                "changed": False,
                "msg": "export is active",
                "data": {"state": "OK", "metrics": {}, "details": ""},
            }

    return {
        "changed": False,
        "msg": "export not found in export list",
        "data": {"state": "CRIT", "metrics": {}, "details": ""},
    }