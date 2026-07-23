def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("hostname") or ""
    port = int(params.get("port") or 25)
    timeout_s = int(params.get("timeout_s") or 30)
    expect = params.get("expect") or "220"
    starttls = params.get("starttls") or False
    fqdn = params.get("fqdn") or ""
    cert_days_warn = params.get("cert_days_warn")
    cert_days_crit = params.get("cert_days_crit")
    resp_warn_s = params.get("response_time_warn_s")
    resp_crit_s = params.get("response_time_crit_s")

    if not host:
        return {"changed": False, "msg": "UNKNOWN", "data": {"state": "UNKNOWN", "metrics": {}, "details": "no host configured"}}

    state = "OK"
    problems = []
    metrics = {}

    probe = ctx.probe("tcp", {"host": host, "port": port, "timeout_s": timeout_s})
    if probe.get("error"):
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": probe["error"]}}

    connect_ms = float(probe.get("connect_ms") or 0)
    banner = probe.get("received") or ""
    metrics["connect_ms"] = connect_ms

    if expect and (expect not in banner):
        state = "CRIT"
        problems.append("expected '%s' not in banner" % expect)

    if resp_crit_s != None and connect_ms >= float(resp_crit_s) * 1000:
        state = "CRIT"
        problems.append("response %d ms" % int(connect_ms))
    elif resp_warn_s != None and connect_ms >= float(resp_warn_s) * 1000:
        if state == "OK":
            state = "WARN"
        problems.append("response %d ms" % int(connect_ms))

    if starttls:
        openssl_cmd = ["timeout", str(timeout_s), "openssl", "s_client",
                       "-starttls", "smtp", "-connect", "%s:%d" % (host, port),
                       "-quiet", "-verify_return_error"]
        if fqdn:
            openssl_cmd = openssl_cmd + ["-name", fqdn]
        tls_r = ctx.run(openssl_cmd, ok_codes=[0, 1, 2, 124])
        if tls_r.rc not in [0, 124]:
            state = "CRIT"
            problems.append("STARTTLS failed")

    if cert_days_warn != None or cert_days_crit != None:
        cert_probe = ctx.probe("tcp", {"host": host, "port": port, "timeout_s": timeout_s,
                                       "tls": True, "verify_tls": False})
        cert_days = cert_probe.get("cert_days_left")
        if cert_days != None:
            metrics["cert_days_left"] = float(cert_days)
            if cert_days_crit != None and float(cert_days) <= float(cert_days_crit):
                state = "CRIT"
                problems.append("cert expires in %d days" % int(cert_days))
            elif cert_days_warn != None and float(cert_days) <= float(cert_days_warn):
                if state == "OK":
                    state = "WARN"
                problems.append("cert expires in %d days" % int(cert_days))

    first_line = ""
    if banner:
        first_line = banner.split("\n")[0].strip()

    detail = "SMTP %s:%d %d ms" % (host, port, int(connect_ms))
    if first_line:
        detail += "; " + first_line[:80]
    if problems:
        detail += " | " + "; ".join(problems)

    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}