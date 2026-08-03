# Checkmk check: ldap
# Active check that probes an LDAP server and grades response time.
# The underlying data source is the `ldapsearch` CLI — if it is not
# installed, discovery returns an empty list and check mode reports
# UNKNOWN rather than reporting a fabricated OK.

def _run_probe(params):
    host = params.get("hostname")
    if host == None or host == "":
        host = "localhost"
    base_dn = params.get("base_dn", "")
    bind_dn = params.get("bind_dn")
    password = params.get("password")
    port = params.get("port")
    version = params.get("version")
    ssl = params.get("ssl", False)
    timeout = params.get("timeout")
    levels = params.get("response_time")
    warn = None
    crit = None
    if levels != None and type(levels) == "list" and len(levels) == 2 and levels[0] == "fixed":
        wc = levels[1]
        if wc != None and len(wc) >= 2:
            warn = wc[0]
            crit = wc[1]

    argv = ["ldapsearch", "-x", "-LLL"]
    if version != None:
        if version == "v2":
            argv.append("-2")
        elif version == "v3":
            argv.append("-3")
        elif version == "v3tls":
            argv.append("-3")
            argv.append("-ZZ")
    if ssl:
        argv.append("-ZZ")
    if host != None and host != "":
        argv.append("-H")
        if ssl:
            argv.append("ldaps://" + host)
        else:
            argv.append("ldap://" + host)
    if port != None:
        argv.append("-p")
        argv.append(str(port))
    if base_dn != None and base_dn != "":
        argv.append("-b")
        argv.append(base_dn)
    if bind_dn != None and bind_dn != "":
        argv.append("-D")
        argv.append(bind_dn)
        if password != None and password != "":
            argv.append("-w")
            argv.append(password)
    if timeout != None:
        argv.append("-t")
        argv.append(str(int(timeout)))
    if warn != None:
        argv.append("-w")
        argv.append(str(int(warn)))
    if crit != None:
        argv.append("-c")
        argv.append(str(int(crit)))
    argv.append("objectClass=*")
    return argv, warn, crit


def _probe_time(ctx, argv):
    start = ctx._now()
    res = ctx.run(argv, mutates=False)
    elapsed = ctx._now() - start
    return res, elapsed


def main(ctx, params):
    name = params.get("name", "")
    if name == None or name == "":
        return {"changed": False, "msg": "no name specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Probe for the real thing: the ldapsearch binary.
    probe = ctx.run(["ldapsearch", "-V"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "ldapsearch not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        desc = "LDAP " + name
        item = name
        return {"changed": False, "msg": "discovered ldap check for " + name,
                "data": {"discovery": [
                    {"item": item,
                     "params": {"response_time": params.get("response_time", ("no_levels", None))},
                     "metrics": ["response_time"]}]}}

    item = params.get("item", name)
    if item != name and item != None and item != "":
        return {"changed": False, "msg": "unknown item: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    argv, warn, crit = _run_probe(params)
    res, elapsed_ms = _probe_time(ctx, argv)
    elapsed_s = elapsed_ms / 1000.0

    if res.rc != 0:
        state = "UNKNOWN"
        msg = "ldap check failed: " + res.stderr
    else:
        state = "OK"
        if warn != None and elapsed_s >= warn:
            state = "WARN"
        if crit != None and elapsed_s >= crit:
            state = "CRIT"
        msg = "LDAP " + name + ": response time %fs" % elapsed_s

    metrics = {}
    if res.rc == 0:
        metrics = {"response_time": elapsed_s}
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": res.stderr}}