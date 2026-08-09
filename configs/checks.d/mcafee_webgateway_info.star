def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Try McAfee Web Gateway OID base
        oid = "1.3.6.1.4.1.1230.2.7.1.3"
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        version_found = False
        if res.rc == 0 and res.stdout.strip() != "" and not _looks_empty(res.stdout):
            version_found = True
        if not version_found:
            # Try Skyhigh Secure Web Gateway OID base
            oid = "1.3.6.1.4.1.59732.2.7.1.3"
            res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
            if res.rc == 0 and res.stdout.strip() != "" and not _looks_empty(res.stdout):
                version_found = True
        if not version_found:
            return {"changed": False, "msg": "no McAfee/Skyhigh Web Gateway detected",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {},
                                        "metrics": ["version", "revision"]}]}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = _snmpget(ctx, host, community, "1.3.6.1.4.1.1230.2.7.1.3")
    revision = _snmpget(ctx, host, community, "1.3.6.1.4.1.1230.2.7.1.9")
    if version == None and revision == None:
        version = _snmpget(ctx, host, community, "1.3.6.1.4.1.59732.2.7.1.3")
        revision = _snmpget(ctx, host, community, "1.3.6.1.4.1.59732.2.7.1.9")
    if version == None and revision == None:
        return {"changed": False, "msg": "no McAfee/Skyhigh Web Gateway found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if version == None:
        version = "unknown"
    if revision == None:
        revision = "unknown"
    msg = "Product version: %s, Revision: %s" % (version, revision)
    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": {}, "details": msg}}


def _looks_empty(s):
    stripped = s.strip()
    if stripped == "" or stripped == "None" or stripped == "0x0":
        return True
    return False


def _snmpget(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if _looks_empty(val):
        return None
    return val