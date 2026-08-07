def _worst(a, b):
    scores = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}
    if (scores.get(b) or 0) > (scores.get(a) or 0):
        return b
    return a

def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    url = params.get("url") or ""
    timeout_s = params.get("timeout_s") or 10
    method_map = {"get": "GET", "head": "HEAD", "post": "POST", "put": "PUT", "delete": "DELETE"}
    method = method_map.get(params.get("method") or "get") or "GET"

    probe_params = {"url": url, "timeout_s": timeout_s, "method": method}

    user_agent = params.get("user_agent")
    if user_agent != None:
        probe_params["user_agent"] = user_agent

    headers = {}
    auth_token_header = params.get("auth_token_header")
    auth_token = params.get("auth_token")
    if auth_token_header != None and auth_token != None:
        headers[auth_token_header] = auth_token
    content_type = params.get("content_type")
    if content_type != None:
        headers["Content-Type"] = content_type
    if len(headers) > 0:
        probe_params["headers"] = headers

    send_body = params.get("send_body")
    if send_body != None:
        probe_params["body"] = send_body

    auth_user = params.get("auth_user")
    auth_password = params.get("auth_password")
    if auth_user != None:
        probe_params["auth_user"] = auth_user
    if auth_password != None:
        probe_params["auth_password"] = auth_password

    virtual_host = params.get("virtual_host")
    if virtual_host != None:
        probe_params["virtual_host"] = virtual_host

    verify_tls = params.get("verify_tls")
    if verify_tls != None:
        probe_params["verify_tls"] = verify_tls

    follow_redirects = params.get("follow_redirects")
    if follow_redirects != None:
        probe_params["follow_redirects"] = follow_redirects

    probe = ctx.probe("http", probe_params)

    if probe.get("error"):
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": probe["error"]}}

    status = int(probe.get("status_code") or 0)
    resp_ms = float(probe.get("response_ms") or 0)
    body = probe.get("body") or ""
    body_bytes = int(probe.get("body_bytes") or 0)
    cert_days = probe.get("cert_days_left")

    state = "OK"
    problems = []

    expected_codes = params.get("expected_status_codes")
    if expected_codes != None and len(expected_codes) > 0:
        if status not in expected_codes:
            state = _worst(state, "WARN")
            problems.append("unexpected status %d" % status)
    else:
        if status >= 500:
            state = _worst(state, "CRIT")
            problems.append("status %d" % status)
        elif status >= 400:
            state = _worst(state, "WARN")
            problems.append("status %d" % status)

    resp_crit = params.get("response_time_crit_ms")
    resp_warn = params.get("response_time_warn_ms")
    if resp_crit != None and resp_ms >= float(resp_crit):
        state = _worst(state, "CRIT")
        problems.append("response %d ms >= crit %d ms" % (int(resp_ms), int(resp_crit)))
    elif resp_warn != None and resp_ms >= float(resp_warn):
        state = _worst(state, "WARN")
        problems.append("response %d ms >= warn %d ms" % (int(resp_ms), int(resp_warn)))

    cert_warn_days = params.get("cert_warn_days")
    cert_crit_days = params.get("cert_crit_days")
    if cert_days != None:
        cert_days_int = int(cert_days)
        if cert_crit_days != None and cert_days_int < int(cert_crit_days):
            state = _worst(state, "CRIT")
            problems.append("cert expires in %d days (crit < %d)" % (cert_days_int, int(cert_crit_days)))
        elif cert_warn_days != None and cert_days_int < int(cert_warn_days):
            state = _worst(state, "WARN")
            problems.append("cert expires in %d days (warn < %d)" % (cert_days_int, int(cert_warn_days)))
    elif url.startswith("https://") and (params.get("check_cert") or cert_warn_days != None or cert_crit_days != None):
        state = _worst(state, "WARN")
        problems.append("no certificate information")

    fetch_body = params.get("fetch_body")
    if fetch_body == None:
        fetch_body = True
    if fetch_body:
        min_size = params.get("min_body_size")
        max_size = params.get("max_body_size")
        if min_size != None and body_bytes < int(min_size):
            state = _worst(state, "WARN")
            problems.append("body %d bytes < min %d" % (body_bytes, int(min_size)))
        if max_size != None and body_bytes > int(max_size):
            state = _worst(state, "WARN")
            problems.append("body %d bytes > max %d" % (body_bytes, int(max_size)))
        body_string = params.get("body_string")
        if body_string != None:
            found = body_string in body
            invert = params.get("body_string_invert") or False
            fail = (found and invert) or (not found and not invert)
            if fail:
                fail_state = params.get("body_fail_state") or "WARN"
                state = _worst(state, fail_state)
                if invert:
                    problems.append("body contains '%s'" % body_string)
                else:
                    problems.append("body missing '%s'" % body_string)

    metrics = {"response_ms": resp_ms, "status_code": float(status)}
    if cert_days != None:
        metrics["cert_days_left"] = float(cert_days)
    if fetch_body:
        metrics["body_bytes"] = float(body_bytes)

    detail = "HTTP %d, %d ms" % (status, int(resp_ms))
    if fetch_body:
        detail += ", %d bytes" % body_bytes
    if cert_days != None:
        detail += ", cert %d days" % int(cert_days)
    if problems:
        detail += " | " + "; ".join(problems)

    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}
