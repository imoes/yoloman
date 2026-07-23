def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("address") or ""
    port = int(params.get("port") or 443)
    timeout_s = int(params.get("timeout_s") or 10)
    connection_type = params.get("connection_type") or "tls"
    allow_self_signed = params.get("allow_self_signed") == True

    state = "OK"
    problems = []
    metrics = {}
    cert_days_left = None
    cert_subject = ""
    connect_ms = 0.0

    if connection_type == "tls":
        probe = ctx.probe("tcp", {
            "host": host,
            "port": port,
            "timeout_s": timeout_s,
            "tls": True,
            "verify_tls": not allow_self_signed,
        })
        err = probe.get("error") or ""
        if err:
            return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": err}}
        connect_ms = float(probe.get("connect_ms") or 0)
        cert_days_left = probe.get("cert_days_left")
        cert_subject = probe.get("cert_subject") or ""
        metrics["connect_ms"] = connect_ms
    else:
        starttls_protos = {
            "smtp_starttls": "smtp",
            "postgres_starttls": "postgres",
            "imap_starttls": "imap",
            "ldap_starttls": "ldap",
        }
        starttls = starttls_protos.get(connection_type) or "smtp"
        if allow_self_signed:
            argv = ["openssl", "s_client", "-starttls", starttls, "-connect", "%s:%d" % (host, port), "-noverify"]
        else:
            argv = ["openssl", "s_client", "-starttls", starttls, "-connect", "%s:%d" % (host, port), "-verify_return_error"]
        res = ctx.run(argv, ok_codes=[0, 1])
        out = (res.stdout or "") + "\n" + (res.stderr or "")
        if res.rc != 0 and res.rc != 1:
            return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": "openssl s_client rc=%d: %s" % (res.rc, (res.stderr or "").split("\n")[0])}}
        if not allow_self_signed and "Verify return code: 0 (ok)" not in out:
            state = "CRIT"
            for line in out.split("\n"):
                if "Verify return code:" in line:
                    problems.append(line.strip())
                    break
            if not problems:
                problems.append("TLS STARTTLS verify failed")
        for line in out.split("\n"):
            ls = line.strip()
            if ls.startswith("subject=") or ls.startswith("subject "):
                cert_subject = ls[8:].strip()
                break

    resp_warn_s = params.get("response_time_warn_s")
    resp_crit_s = params.get("response_time_crit_s")
    if resp_crit_s != None and connect_ms / 1000.0 >= float(resp_crit_s):
        state = "CRIT"
        problems.append("response %d ms" % int(connect_ms))
    elif resp_warn_s != None and connect_ms / 1000.0 >= float(resp_warn_s):
        if state == "OK":
            state = "WARN"
        problems.append("response %d ms" % int(connect_ms))

    if cert_days_left != None:
        metrics["cert_days_left"] = float(cert_days_left)
        days_crit = params.get("days_crit")
        days_warn = params.get("days_warn")
        if days_crit != None and int(cert_days_left) <= int(days_crit):
            state = "CRIT"
            problems.append("cert expires in %d days" % int(cert_days_left))
        elif days_warn != None and int(cert_days_left) <= int(days_warn):
            if state == "OK":
                state = "WARN"
            problems.append("cert expires in %d days" % int(cert_days_left))

    subject_cn = params.get("subject_cn")
    if subject_cn != None and cert_subject:
        if subject_cn not in cert_subject:
            if state == "OK":
                state = "WARN"
            problems.append("subject CN mismatch (expected %s)" % subject_cn)

    detail = "%s:%d [%s]" % (host, port, connection_type)
    if cert_days_left != None:
        detail += ", expires in %d days" % int(cert_days_left)
    if cert_subject:
        detail += " (%s)" % cert_subject
    if problems:
        detail += " | " + "; ".join(problems)

    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}
