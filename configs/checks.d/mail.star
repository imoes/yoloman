def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    server = params.get("server") or ""
    protocol = params.get("protocol") or "IMAP"
    tls = params.get("tls")
    if tls == None:
        tls = False
    timeout_s = params.get("timeout_s") or 60
    username = params.get("username") or ""
    password = params.get("password") or ""

    port = params.get("port")
    if port == None:
        if protocol == "POP3":
            if tls:
                port = 995
            else:
                port = 110
        elif protocol == "EWS" or protocol == "GRAPHAPI":
            port = 443
        else:
            if tls:
                port = 993
            else:
                port = 143

    state = "OK"
    problems = []
    metrics = {}

    if protocol == "EWS" or protocol == "GRAPHAPI":
        scheme = "https"
        if not tls:
            scheme = "http"
        path = ""
        if protocol == "EWS":
            path = "/EWS/Exchange.asmx"
        url = "%s://%s:%d%s" % (scheme, server, int(port), path)
        probe_params = {"url": url, "timeout_s": timeout_s, "verify_tls": tls}
        if username:
            probe_params["auth_user"] = username
        if password:
            probe_params["auth_password"] = password
        probe = ctx.probe("http", probe_params)
        if probe.get("error"):
            return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": probe["error"]}}
        resp_ms = float(probe.get("response_ms") or 0)
        metrics["response_ms"] = resp_ms
        cert_days = probe.get("cert_days_left")
        if cert_days != None and tls:
            metrics["cert_days_left"] = float(cert_days)
            crit_days = params.get("cert_crit_days")
            warn_days = params.get("cert_warn_days")
            if crit_days != None and int(cert_days) <= int(crit_days):
                state = "CRIT"
                problems.append("cert expires in %d days" % int(cert_days))
            elif warn_days != None and int(cert_days) <= int(warn_days):
                if state == "OK":
                    state = "WARN"
                problems.append("cert expires in %d days" % int(cert_days))
        detail = "%s %s:%d - %d ms" % (protocol, server, int(port), int(resp_ms))
    else:
        probe = ctx.probe("tcp", {"host": server, "port": int(port), "timeout_s": timeout_s, "tls": tls, "verify_tls": tls})
        if probe.get("error"):
            return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": probe["error"]}}
        connect_ms = float(probe.get("connect_ms") or 0)
        metrics["connect_ms"] = connect_ms
        cert_days = probe.get("cert_days_left")
        if cert_days != None and tls:
            metrics["cert_days_left"] = float(cert_days)
            crit_days = params.get("cert_crit_days")
            warn_days = params.get("cert_warn_days")
            if crit_days != None and int(cert_days) <= int(crit_days):
                state = "CRIT"
                problems.append("cert expires in %d days" % int(cert_days))
            elif warn_days != None and int(cert_days) <= int(warn_days):
                if state == "OK":
                    state = "WARN"
                problems.append("cert expires in %d days" % int(cert_days))
        detail = "%s %s:%d - %d ms" % (protocol, server, int(port), int(connect_ms))

    if problems:
        detail = detail + " | " + "; ".join(problems)

    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}
