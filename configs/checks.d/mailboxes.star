def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("server") or params.get("hostname") or ""
    protocol = params.get("protocol") or "IMAP"
    tls = params.get("tls")
    if tls == None:
        tls = True
    timeout_s = int(params.get("timeout_s") or 10)
    port = params.get("port")
    if port == None:
        if protocol == "POP3":
            port = 995 if tls else 110
        else:
            port = 993 if tls else 143
    port = int(port)
    cert_days_warn = params.get("cert_days_warn")
    cert_days_crit = params.get("cert_days_crit")
    resp_warn_ms = params.get("response_time_warn_ms")
    resp_crit_ms = params.get("response_time_crit_ms")

    if not host:
        return {"changed": False, "msg": "UNKNOWN", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no mail server configured"}}

    state = "OK"
    problems = []
    metrics = {}

    probe = ctx.probe("tcp", {"host": host, "port": port, "timeout_s": timeout_s, "tls": tls, "verify_tls": False})
    if probe.get("error"):
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": "%s %s:%d unreachable: %s" % (protocol, host, port, probe["error"])}}

    connect_ms = float(probe.get("connect_ms") or 0)
    metrics["connect_ms"] = connect_ms

    if resp_crit_ms != None and connect_ms >= float(resp_crit_ms):
        state = "CRIT"
        problems.append("connect %d ms" % int(connect_ms))
    elif resp_warn_ms != None and connect_ms >= float(resp_warn_ms):
        if state == "OK":
            state = "WARN"
        problems.append("connect %d ms" % int(connect_ms))

    if tls:
        cert_days = probe.get("cert_days_left")
        if cert_days != None:
            metrics["cert_days_left"] = float(cert_days)
            if cert_days_crit != None and float(cert_days) <= float(cert_days_crit):
                state = "CRIT"
                problems.append("cert expires in %d days" % int(cert_days))
            elif cert_days_warn != None and float(cert_days) <= float(cert_days_warn):
                if state == "OK":
                    state = "WARN"
                problems.append("cert expires in %d days" % int(cert_days))

    detail = "%s %s:%d reachable, %d ms" % (protocol, host, port, int(connect_ms))
    if problems:
        detail += " | " + "; ".join(problems)
    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}
