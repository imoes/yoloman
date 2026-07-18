def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    smtp_host = params.get("send_server") or params.get("smtp_server") or ""
    smtp_port = int(params.get("send_port") or 25)
    smtp_tls = params.get("send_tls") or False
    fetch_host = params.get("fetch_server") or ""
    fetch_protocol = params.get("fetch_protocol") or "IMAP"
    fetch_tls = params.get("fetch_tls")
    if fetch_tls == None:
        fetch_tls = True
    fetch_port = params.get("fetch_port")
    if fetch_port == None:
        if fetch_protocol == "POP3":
            fetch_port = 995 if fetch_tls else 110
        else:
            fetch_port = 993 if fetch_tls else 143
    fetch_port = int(fetch_port)
    timeout_s = int(params.get("timeout_s") or 10)
    cert_days_warn = params.get("cert_days_warn")
    cert_days_crit = params.get("cert_days_crit")

    if not smtp_host or not fetch_host:
        return {"changed": False, "msg": "UNKNOWN", "data": {"state": "UNKNOWN", "metrics": {}, "details": "both a send (SMTP) and a fetch (IMAP/POP3) server are required"}}

    state = "OK"
    problems = []
    metrics = {}

    # Leg 1: the SMTP server we send the loop mail through must accept connections.
    send_probe = ctx.probe("tcp", {"host": smtp_host, "port": smtp_port, "timeout_s": timeout_s, "tls": smtp_tls, "verify_tls": False})
    if send_probe.get("error"):
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": "SMTP %s:%d unreachable: %s" % (smtp_host, smtp_port, send_probe["error"])}}
    send_ms = float(send_probe.get("connect_ms") or 0)
    metrics["smtp_connect_ms"] = send_ms

    # Leg 2: the mailbox we expect the mail to loop back into must be reachable.
    fetch_probe = ctx.probe("tcp", {"host": fetch_host, "port": fetch_port, "timeout_s": timeout_s, "tls": fetch_tls, "verify_tls": False})
    if fetch_probe.get("error"):
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": metrics, "details": "%s %s:%d unreachable: %s" % (fetch_protocol, fetch_host, fetch_port, fetch_probe["error"])}}
    fetch_ms = float(fetch_probe.get("connect_ms") or 0)
    metrics["fetch_connect_ms"] = fetch_ms

    if fetch_tls:
        cert_days = fetch_probe.get("cert_days_left")
        if cert_days != None:
            metrics["cert_days_left"] = float(cert_days)
            if cert_days_crit != None and float(cert_days) <= float(cert_days_crit):
                state = "CRIT"
                problems.append("fetch cert expires in %d days" % int(cert_days))
            elif cert_days_warn != None and float(cert_days) <= float(cert_days_warn):
                if state == "OK":
                    state = "WARN"
                problems.append("fetch cert expires in %d days" % int(cert_days))

    detail = "SMTP %s:%d and %s %s:%d reachable (%d/%d ms)" % (smtp_host, smtp_port, fetch_protocol, fetch_host, fetch_port, int(send_ms), int(fetch_ms))
    if problems:
        detail += " | " + "; ".join(problems)
    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}
