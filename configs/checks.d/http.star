def _grade_levels(value, warn, crit):
    # upper-bound grading: value >= crit -> CRIT, >= warn -> WARN
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    # Active HTTP service check (Checkmk "Check HTTP service" / check_http):
    # fetch a URL via ctx.probe("http") and grade status / response time /
    # content / certificate age against the configured parameters. Assigned
    # per host with parameters (service_name, url, ...) — one Service per
    # assignment instance.
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    url = params.get("url") or ""
    if not url:
        # Convenience: build the url from host/port/uri/ssl like check_http.
        host = params.get("host") or params.get("virtual_host") or "localhost"
        port = params.get("port")
        scheme = "https" if params.get("ssl") else "http"
        hostport = host
        if port and int(port) not in (80, 443):
            hostport = "%s:%d" % (host, int(port))
        url = "%s://%s%s" % (scheme, hostport, params.get("uri") or "/")

    probe = ctx.probe("http", {
        "url": url,
        "method": params.get("method") or "GET",
        "timeout_s": params.get("timeout_s") or 10,
        "verify_tls": params.get("verify_tls", True),
        "follow_redirects": params.get("follow_redirects", True),
        "user_agent": params.get("user_agent") or "bossman-check/1.0",
        "auth_user": params.get("auth_user") or "",
        "auth_password": params.get("auth_password") or "",
        "virtual_host": params.get("virtual_host") or "",
        "body": params.get("post_data") or "",
        "headers": params.get("headers") or {},
    })

    if probe.get("error"):
        return {"changed": False, "msg": "CRIT", "data": {
            "state": "CRIT", "metrics": {},
            "details": "%s — %s" % (url, probe["error"]),
        }}

    status = int(probe.get("status_code") or 0)
    resp_ms = float(probe.get("response_ms") or 0)
    body = probe.get("body") or ""
    state = "OK"
    problems = []

    # HTTP status grading: expected list wins; otherwise >=500 CRIT, >=400 WARN.
    expect_status = params.get("expect_status") or []
    if expect_status:
        ok_status = False
        for s in expect_status:
            if int(s) == status:
                ok_status = True
        if not ok_status:
            state = "CRIT"
            problems.append("status %d (expected %s)" % (status, expect_status))
    elif status >= 500:
        state = "CRIT"
        problems.append("status %d" % status)
    elif status >= 400:
        state = "WARN"
        problems.append("status %d" % status)

    # Content matching: substring expected in the response body; invert flips it.
    expect_string = params.get("expect_string") or ""
    if expect_string:
        found = expect_string in body
        if params.get("invert_match", False):
            found = not found
        if not found:
            state = "CRIT"
            problems.append("expected content %r not found" % expect_string)

    # Response-time thresholds (ms).
    rt = _grade_levels(resp_ms, params.get("response_time_warn_ms"), params.get("response_time_crit_ms"))
    if rt != "OK":
        if state == "OK" or (state == "WARN" and rt == "CRIT"):
            state = rt
        problems.append("response time %d ms" % int(resp_ms))

    # Certificate age (https): warn/crit on days left.
    metrics = {"response_ms": resp_ms, "status_code": status}
    cert_days = probe.get("cert_days_left")
    if cert_days != None:
        metrics["cert_days_left"] = cert_days
        cw = params.get("cert_warn_days")
        cc = params.get("cert_crit_days")
        if cc != None and cert_days <= cc:
            state = "CRIT"
            problems.append("certificate expires in %d days" % cert_days)
        elif cw != None and cert_days <= cw:
            if state == "OK":
                state = "WARN"
            problems.append("certificate expires in %d days" % cert_days)

    # Page size lower bound (bytes).
    size = int(probe.get("body_bytes") or 0)
    metrics["body_bytes"] = size
    min_size = params.get("min_size_bytes")
    if min_size != None and size < int(min_size):
        state = "CRIT"
        problems.append("page size %d B below minimum %d B" % (size, int(min_size)))

    detail = "%s — HTTP %d, %d ms, %d B" % (url, status, int(resp_ms), size)
    if cert_days != None:
        detail += ", cert %d days left" % cert_days
    if problems:
        detail += " | " + "; ".join(problems)

    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}
