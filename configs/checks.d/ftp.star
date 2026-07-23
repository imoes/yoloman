def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("host") or ""
    port = int(params.get("port") or 21)
    timeout_s = params.get("timeout_s") or 10
    use_ssl = params.get("ssl") or False

    probe_params = {
        "host": host,
        "port": port,
        "timeout_s": timeout_s,
        "tls": use_ssl,
        "verify_tls": use_ssl,
    }

    send_string = params.get("send_string")
    if send_string != None:
        probe_params["send"] = send_string

    probe = ctx.probe("tcp", probe_params)

    if probe.get("error"):
        err = probe.get("error") or ""
        refuse_state = params.get("refuse_state") or "crit"
        if "refused" in err:
            state = refuse_state.upper()
        else:
            state = "CRIT"
        return {"changed": False, "msg": state, "data": {"state": state, "metrics": {}, "details": err}}

    connect_ms = float(probe.get("connect_ms") or 0)
    state = "OK"
    problems = []

    crit_ms = params.get("response_time_crit_ms")
    warn_ms = params.get("response_time_warn_ms")
    if crit_ms != None and connect_ms >= float(crit_ms):
        state = "CRIT"
        problems.append("response time %d ms" % int(connect_ms))
    elif warn_ms != None and connect_ms >= float(warn_ms):
        state = "WARN"
        problems.append("response time %d ms" % int(connect_ms))

    expect = params.get("expect") or []
    received = probe.get("received") or ""
    for s in expect:
        if s not in received:
            if state != "CRIT":
                state = "CRIT"
            problems.append("expected '%s' not found" % s)

    cert_days_left = probe.get("cert_days_left")
    cert_days_warn = params.get("cert_days_warn")
    cert_days_crit = params.get("cert_days_crit")
    if cert_days_left != None:
        days = float(cert_days_left)
        if cert_days_crit != None and days <= float(cert_days_crit):
            state = "CRIT"
            problems.append("cert expires in %d days" % int(days))
        elif cert_days_warn != None and days <= float(cert_days_warn):
            if state == "OK":
                state = "WARN"
            problems.append("cert expires in %d days" % int(days))

    detail = "FTP %s:%d connected, %d ms" % (host, port, int(connect_ms))
    if problems:
        detail += " | " + "; ".join(problems)

    metrics = {"connect_ms": connect_ms}
    if cert_days_left != None:
        metrics["cert_days_left"] = float(cert_days_left)

    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}
