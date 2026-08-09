# Checkmk active check: smtp — read-only Starlark check module.
#
# Builds and runs the `check_smtp` Nagios plugin command line, mirroring the
# parameters Checkmk would pass it, and grades the result. Never mutates.

def _to_float(s):
    # Best-effort float parse without try/except.
    f = float(s) if hasattr(float(s), "real") else None
    return f


def _parse_float_token(word):
    # Return float(word) if word parses as a float, else None.
    neg = word.startswith("-")
    body = word[1:] if neg else word
    if "." in body:
        intpart, frac = body.split(".", 1)
    else:
        intpart, frac = body, ""
    ok = True
    if intpart == "" and frac == "":
        ok = False
    if intpart != "" and not intpart.isdigit():
        ok = False
    if frac != "" and not frac.isdigit():
        ok = False
    if not ok:
        return None
    v = float(word)
    if neg:
        v = -v
    return v


def _resolve_host(params, host_config):
    hostname = params.get("hostname")
    address_family = params.get("address_family", "primary")
    target_host = hostname
    if address_family in ("ipv4", "ipv6"):
        ip_opt = "-4" if address_family == "ipv4" else "-6"
    else:
        ip_opt = "-4"
    if target_host:
        return target_host, ip_opt
    primary = host_config.get("primary_ip_config") if host_config else None
    if primary:
        ip_opt = "-4" if primary.get("family") == "ipv4" else "-6"
        return primary.get("address"), ip_opt
    if address_family == "ipv6":
        return None, None
    return None, None


def _build_args(params, host_config):
    args = []
    expect = params.get("expect")
    if expect:
        args.extend(["-e", expect])
    port = params.get("port")
    if port:
        args.extend(["-p", str(port)])
    commands = params.get("commands")
    if commands:
        for c in commands:
            args.extend(["-C", c])
    command_responses = params.get("command_responses")
    if command_responses:
        for r in command_responses:
            args.extend(["-R", r])
    from_address = params.get("from_address")
    if from_address:
        args.extend(["-f", str(from_address)])
    rt = params.get("response_time", ["no_levels", None])
    if len(rt) == 2 and rt[0] == "fixed" and rt[1] != None:
        warn, crit = rt[1]
        args.extend(["-w", "%f" % warn, "-c", "%f" % crit])
    timeout = params.get("timeout")
    if timeout != None:
        args.extend(["-t", str(int(timeout))])
    auth = params.get("auth")
    if auth:
        args.extend(["-A", "LOGIN", "-U", auth.get("username", ""), "-P", auth.get("password", "")])
    if params.get("starttls"):
        args.append("-S")
    fqdn = params.get("fqdn")
    if fqdn:
        args.extend(["-F", str(fqdn)])
    cert_days = params.get("cert_days", ["no_levels", None])
    if len(cert_days) == 2 and cert_days[0] == "fixed" and cert_days[1] != None:
        warn, crit = cert_days[1]
        warn_s = warn / 86400.0
        crit_s = crit / 86400.0
        args.extend(["-D", "%d,%d" % (int(warn_s), int(crit_s))])
    host, ip_opt = _resolve_host(params, host_config)
    if host == None:
        return None
    args.extend([ip_opt, "-H", host])
    return args


def _grade_response_time(rt, value):
    spec = rt
    if len(spec) == 2 and spec[0] == "fixed" and spec[1] != None:
        warn, crit = spec[1]
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
    return "OK"


def _grade_cert_days(cd, value):
    spec = cd
    if len(spec) == 2 and spec[0] == "fixed" and spec[1] != None:
        warn, crit = spec[1]
        if value <= crit:
            return "CRIT"
        if value <= warn:
            return "WARN"
    return "OK"


def main(ctx, params):
    host_config = params.get("host_config")
    if params.get("_discover"):
        if not params.get("hostname") and not params.get("port"):
            return {"changed": False, "msg": "no SMTP target configured",
                    "data": {"discovery": []}}
        name = params.get("name", "smtp")
        desc = name
        if not desc.startswith("SMTP"):
            desc = "SMTP " + desc
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "",
                                        "params": {"response_time": params.get("response_time", ["no_levels", None]),
                                                   "cert_days": params.get("cert_days", ["no_levels", None])},
                                        "metrics": ["response_time", "cert_days"]}]}}

    if not params.get("hostname") and not params.get("port"):
        return {"changed": False, "msg": "no SMTP target configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    args = _build_args(params, host_config)
    if args == None:
        return {"changed": False, "msg": "host not resolved",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cmd = ["check_smtp"]
    cmd.extend(args)
    res = ctx.run(cmd, mutates=False)

    if res.rc == 127:
        return {"changed": False, "msg": "check_smtp plugin not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if res.rc == 0:
        state = "OK"
    elif res.rc == 1:
        state = "WARN"
    elif res.rc == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    metrics = {}
    out = res.stdout
    rt_val = None
    cd_val = None
    for line in out.split("\n"):
        low = line.lower()
        if rt_val == None and "response time" in low:
            words = line.split()
            for w in words:
                cand = _parse_float_token(w)
                if cand != None:
                    rt_val = cand
                    break
        if cd_val == None and "days" in low and ("cert" in low or "expire" in low):
            words = line.split()
            for w in words:
                cand = _parse_float_token(w)
                if cand != None:
                    cd_val = cand
                    break
    if rt_val != None:
        metrics["response_time"] = rt_val
    if cd_val != None:
        metrics["cert_days"] = cd_val

    rt = params.get("response_time", ["no_levels", None])
    if rt_val != None and state == "OK":
        rt_state = _grade_response_time(rt, rt_val)
        if rt_state != "OK":
            state = rt_state
    cd = params.get("cert_days", ["no_levels", None])
    if cd_val != None and state == "OK":
        cd_state = _grade_cert_days(cd, cd_val)
        if cd_state != "OK":
            state = cd_state

    if state == "OK":
        msg = "SMTP service OK"
    elif state == "WARN":
        msg = "SMTP WARNING: " + out.strip()
    elif state == "CRIT":
        msg = "SMTP CRITICAL: " + out.strip()
    else:
        msg = "SMTP " + out.strip()

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": out.strip()}}