def main(ctx, params):
    base = ".1.3.6.1.4.1.334.72.1.1.6.3"
    users_oid = base + ".6"
    domino_prefixes = [
        ".1.3.6.1.4.1.311.1.1.3.1.2",
        ".1.3.6.1.4.1.8072.3.1.10",
        ".1.3.6.1.4.1.8072.3.2.10",
    ]
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    def _is_domino(sid):
        for p in domino_prefixes:
            if sid == p or sid.startswith(p + "."):
                return True
        return False

    def _sysid_match():
        sysid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid.rc != 0:
            return False
        return _is_domino(sysid.stdout.strip())

    if params.get("_discover"):
        if not _sysid_match():
            return {"changed": False, "msg": "not a Domino host", "data": {"discovery": []}}
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, users_oid], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "Domino users OID not reachable", "data": {"discovery": []}}
        levels = params.get("levels", (1000, 1500))
        w = levels[0] if len(levels) > 0 else 1000
        c = levels[1] if len(levels) > 1 else 1500
        return {
            "changed": False,
            "msg": "discovered Domino Users service",
            "data": {"discovery": [
                {"item": "", "params": {"levels": [w, c]}, "metrics": ["users"]},
            ]},
        }

    levels = params.get("levels", (1000, 1500))
    warn = levels[0] if len(levels) > 0 else 1000
    crit = levels[1] if len(levels) > 1 else 1500

    if not _sysid_match():
        return {"changed": False, "msg": "not a Domino host", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, users_oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read Domino users count via SNMP", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    if not raw or not raw.isdigit():
        return {"changed": False, "msg": "invalid Domino users value: %s" % raw, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    users = int(raw)
    state = "CRIT" if users >= crit else ("WARN" if users >= warn else "OK")
    return {
        "changed": False,
        "msg": "Domino users on server: %d" % users,
        "data": {"state": state, "metrics": {"users": users}, "details": ""},
    }