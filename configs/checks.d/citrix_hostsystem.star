def _parse_xe_field(stdout, field):
    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(field):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val:
                    return val
    return ""

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["xe", "pool-list", "params=name-label"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        pool = _parse_xe_field(res.stdout, "name-label")
        if not pool:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": []},
            ]},
        }

    res = ctx.run(["xe", "pool-list", "params=name-label"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "xe pool-list failed: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr.strip()},
        }
    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "xe pool-list returned no output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    pool = _parse_xe_field(res.stdout, "name-label")
    if not pool:
        return {
            "changed": False,
            "msg": "No Citrix pool name found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "Citrix Pool Name: " + pool,
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }