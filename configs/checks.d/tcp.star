def _state_max(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(b, 0) > order.get(a, 0):
        return b
    return a

def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("host") or ""
    port = int(params.get("port") or 0)
    timeout_s = params.get("timeout_s") or 10
    use_ssl = params.get("ssl") or False
    send_string = params.get("send_string") or ""

    if params.get("escape_send_string"):
        send_string = send_string.replace("\\n", "\n").replace("\\r", "\r").replace("\\t", "\t")

    probe = ctx.probe("tcp", {
        "host": host,
        "port": port,
        "timeout_s": timeout_s,
        "send": send_string,
        "tls": use_ssl,
        "verify_tls": use_ssl,
    })

    err = probe.get("error") or ""
    if err:
        refuse_state = (params.get("refuse_state") or "crit").upper()
        if "refused" in err.lower():
            return {
                "changed": False,
                "msg": refuse_state,
                "data": {
                    "state": refuse_state,
                    "metrics": {},
                    "details": "Connection refused to %s:%d" % (host, port),
                },
            }
        return {
            "changed": False,
            "msg": "CRIT",
            "data": {"state": "CRIT", "metrics": {}, "details": err},
        }

    connect_ms = float(probe.get("connect_ms") or 0)
    state = "OK"
    problems = []
    metrics = {"connect_ms": connect_ms}

    resp_warn = params.get("response_time_warn_s")
    resp_crit = params.get("response_time_crit_s")
    if resp_crit != None and connect_ms >= resp_crit * 1000:
        state = _state_max(state, "CRIT")
        problems.append("response time %d ms" % int(connect_ms))
    elif resp_warn != None and connect_ms >= resp_warn * 1000:
        state = _state_max(state, "WARN")
        problems.append("response time %d ms" % int(connect_ms))

    expect = params.get("expect") or []
    if expect:
        received = probe.get("received") or ""
        jail = params.get("jail") or False
        mismatch_state = (params.get("mismatch_state") or "warn").upper()
        expect_all = params.get("expect_all") or False

        if expect_all:
            missing = [s for s in expect if s not in received]
            if missing:
                state = _state_max(state, mismatch_state)
                problems.append("missing: " + ", ".join(missing))
        else:
            found = False
            for s in expect:
                if s in received:
                    found = True
                    break
            if not found:
                state = _state_max(state, mismatch_state)
                problems.append("none of expected strings found")

        if not jail and received:
            problems.append("response: " + received[:200])

    cert_days_left = probe.get("cert_days_left")
    if use_ssl and cert_days_left != None:
        metrics["cert_days_left"] = float(cert_days_left)
        cert_crit = params.get("cert_days_crit")
        cert_warn = params.get("cert_days_warn")
        if cert_crit != None and cert_days_left <= cert_crit:
            state = _state_max(state, "CRIT")
            problems.append("cert expires in %d days" % int(cert_days_left))
        elif cert_warn != None and cert_days_left <= cert_warn:
            state = _state_max(state, "WARN")
            problems.append("cert expires in %d days" % int(cert_days_left))

    detail = "TCP %s:%d connected in %d ms" % (host, port, int(connect_ms))
    if problems:
        detail += " | " + "; ".join(problems)

    return {"changed": False, "msg": state, "data": {"state": state, "metrics": metrics, "details": detail}}
