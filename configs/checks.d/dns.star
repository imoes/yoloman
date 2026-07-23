def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}
    hostname = params.get("hostname") or ""
    timeout_s = params.get("timeout_s") or 10
    rtype = params.get("rtype") or "A"
    probe = ctx.probe("dns", {"name": hostname, "rtype": rtype, "timeout_s": timeout_s})
    if probe.get("error"):
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": "DNS lookup failed: " + probe["error"]}}
    resolve_ms = probe.get("resolve_ms") or 0
    records = probe.get("records") or []
    state = "OK"
    problems = []
    expected = params.get("expected_addresses_list") or []
    if expected:
        expect_all = params.get("expect_all_addresses")
        if expect_all == None:
            expect_all = True
        if expect_all:
            missing = [a for a in expected if a not in records]
            if missing:
                state = "CRIT"
                problems.append("missing: " + ", ".join(missing))
        else:
            matched = [a for a in expected if a in records]
            if not matched:
                state = "CRIT"
                problems.append("none of expected addresses found")
    warn_s = params.get("response_time_warn_s")
    crit_s = params.get("response_time_crit_s")
    if crit_s != None and resolve_ms >= crit_s * 1000:
        state = "CRIT"
        problems.append("slow %d ms" % int(resolve_ms))
    elif warn_s != None and resolve_ms >= warn_s * 1000:
        if state == "OK":
            state = "WARN"
        problems.append("slow %d ms" % int(resolve_ms))
    answers = ", ".join(records) if records else "(no records)"
    detail = "DNS %s -> %s (%d ms)" % (hostname, answers, int(resolve_ms))
    if problems:
        detail += " | " + "; ".join(problems)
    return {"changed": False, "msg": state, "data": {"state": state, "metrics": {"resolve_ms": resolve_ms}, "details": detail}}