def main(ctx, params):
    if params.get("_discover"):
        if not _probe_present(ctx, params):
            return {"changed": False, "msg": "no Domino detected",
                    "data": {"discovery": []}}
        section = _fetch(ctx, params)
        if not section or len(section[0]) == 0:
            return {"changed": False, "msg": "no Domino info available",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered Domino Info",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}

    if not _probe_present(ctx, params):
        return {"changed": False, "msg": "no Domino detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _fetch(ctx, params)
    if not section:
        return {"changed": False, "msg": "no Domino info available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status, domain, name, release = section[0]
    state_readable = _STATUS_MAP.get(status)
    if state_readable == None:
        return {"changed": False, "msg": "unknown Domino status code: %s" % str(status),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state, readable = state_readable
    msg = "Server is %s" % readable
    if len(domain) > 0:
        msg = msg + ", Domain: %s" % domain
    msg = msg + ", Name: %s, %s" % (name, release)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}


_STATUS_MAP = {
    "1": ("OK", "up"),
    "2": ("CRIT", "down"),
    "3": ("CRIT", "not-responding"),
    "4": ("WARN", "crashed"),
    "5": ("UNKNOWN", "unknown"),
}

_SYS_OID = ".1.3.6.1.2.1.1.2.0"
_DETECT_WALK = [".1.3.6.1.4.1.311.1.1.3.1.2", ".1.3.6.1.4.1.8072.3.1.10", ".1.3.6.1.4.1.8072.3.2.10"]
_BASE = ".1.3.6.1.4.1.334.72"
_FETCH_OIDS = ["2.2", "1.1.4.8", "1.1.6.2.1", "1.1.6.2.4"]


def _probe_present(ctx, params):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
         params.get("host", "localhost"), _SYS_OID],
        mutates=False)
    if res.rc != 0:
        return False
    sys_oid = res.stdout.strip()
    for prefix in _DETECT_WALK:
        if sys_oid.startswith(prefix):
            return True
    return False


def _fetch(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    rows = []
    for rel in _FETCH_OIDS:
        oid = _BASE + "." + rel
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False)
        if res.rc != 0:
            return []
        rows.append(res.stdout.strip())
    if len(rows) < 4:
        return []
    return [rows]