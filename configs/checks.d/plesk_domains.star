# Translated Checkmk check: plesk_domains → read-only Starlark check module.

def _is_plesk_installed(ctx):
    res = ctx.run(["which", "plesk"], mutates=False)
    if res.rc == 0 and res.stdout.strip():
        return True
    res2 = ctx.run(["plesk", "--version"], mutates=False)
    if res2.rc == 0 and res2.stdout.strip():
        return True
    return False

def _count_domains(ctx):
    res = ctx.run(["plesk", "domain", "--list"], mutates=False)
    if res.rc != 0:
        return None
    lines = [l for l in res.stdout.splitlines() if l.strip()]
    return lines

def main(ctx, params):
    if params.get("_discover"):
        if not _is_plesk_installed(ctx):
            return {
                "changed": False,
                "msg": "Plesk not installed",
                "data": {"discovery": []},
            }
        domains = _count_domains(ctx)
        if domains == None or len(domains) == 0:
            return {
                "changed": False,
                "msg": "No domains configured",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["domains"],
                    }
                ],
            },
        }

    if not _is_plesk_installed(ctx):
        return {
            "changed": False,
            "msg": "Plesk not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    domains = _count_domains(ctx)
    if domains == None:
        return {
            "changed": False,
            "msg": "Failed to query domains",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if len(domains) == 0:
        return {
            "changed": False,
            "msg": "No domains configured",
            "data": {"state": "WARN", "metrics": {"domains": 0}, "details": ""},
        }
    summary = "%d domain(s) configured" % len(domains)
    details = "\n".join(domains)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {"domains": len(domains)},
            "details": details,
        },
    }