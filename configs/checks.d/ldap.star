def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("hostname") or ""
    port = params.get("port")
    ssl = params.get("ssl") or False
    version = params.get("version") or "v2"
    base_dn = params.get("base_dn") or ""
    timeout_s = params.get("timeout_s") or 10
    bind_dn = params.get("bind_dn")
    password = params.get("password")

    if ssl:
        if port == None:
            port = 636
        scheme = "ldaps"
        probe_tls = True
    else:
        if port == None:
            port = 389
        scheme = "ldap"
        probe_tls = False

    probe = ctx.probe("tcp", {
        "host": host,
        "port": int(port),
        "timeout_s": int(timeout_s),
        "tls": probe_tls,
        "verify_tls": probe_tls,
    })

    if probe.get("error"):
        return {"changed": False, "msg": "CRIT", "data": {
            "state": "CRIT", "metrics": {}, "details": probe["error"]
        }}

    connect_ms = float(probe.get("connect_ms") or 0)
    state = "OK"
    problems = []

    crit_s = params.get("response_time_crit_s")
    warn_s = params.get("response_time_warn_s")
    if crit_s != None and connect_ms >= float(crit_s) * 1000:
        state = "CRIT"
        problems.append("response time %d ms" % int(connect_ms))
    elif warn_s != None and connect_ms >= float(warn_s) * 1000:
        state = "WARN"
        problems.append("slow %d ms" % int(connect_ms))

    url = "%s://%s:%d" % (scheme, host, int(port))
    argv = ["ldapsearch", "-x", "-H", url, "-b", base_dn, "-s", "base",
            "-l", str(int(timeout_s))]
    if version == "v3" or version == "v3tls":
        argv += ["-P", "3"]
        if version == "v3tls":
            argv.append("-ZZ")
    else:
        argv += ["-P", "2"]
    if bind_dn != None:
        argv += ["-D", bind_dn]
        if password != None:
            argv += ["-w", password]
    attribute = params.get("attribute")
    if attribute != None:
        argv.append(attribute)

    run = ctx.run(argv, ok_codes=[0, 4])
    if run.rc != 0 and run.rc != 4:
        if state != "CRIT":
            state = "CRIT"
        problems.append("ldap error (rc=%d)" % run.rc)

    proto_label = "LDAPS" if ssl else "LDAP"
    detail = "%s %s:%d base=%s %d ms" % (proto_label, host, int(port), base_dn, int(connect_ms))
    if problems:
        detail += " | " + "; ".join(problems)

    return {"changed": False, "msg": state, "data": {
        "state": state,
        "metrics": {"connect_ms": connect_ms},
        "details": detail,
    }}
