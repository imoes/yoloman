# cert.star — translated from checkmk.cert (server-side active check plugin).

def _split_lines(s):
    return s.split("\n")

def _day_seconds():
    return 86400.0

def _to_float(v):
    if v == None:
        return None
    if type(v) == "float" or type(v) == "int":
        return float(v)
    s = str(v).strip()
    if s == "":
        return None
    neg = False
    num = s
    if s.startswith("-"):
        neg = True
        num = s[1:]
    if "." in num:
        parts = num.split(".", 2)
        if len(parts) != 2:
            return None
        head, tail = parts
        if head.isdigit() and tail.isdigit():
            val = 0.0
            for ch in head:
                val = val * 10.0 + (ord(ch) - 48)
            frac = 0.0
            base = 0.1
            for ch in tail:
                frac = frac + (ord(ch) - 48) * base
                base = base * 0.1
            val = val + frac
            if neg:
                val = 0.0 - val
            return val
        return None
    if num.isdigit():
        val = 0.0
        for ch in num:
            val = val * 10.0 + (ord(ch) - 48)
        if neg:
            val = 0.0 - val
        return val
    return None

def _round3(x):
    if x == None:
        return 0.0
    v = float(x)
    return int(v * 1000.0 + 0.5) / 1000.0

def _round0(x):
    if x == None:
        return 0
    v = float(x)
    return int(v + 0.5)

def _grade_upper(value, levels):
    if levels == None or len(levels) < 2:
        return "OK"
    warn, crit = levels[0], levels[1]
    if value == None:
        return "OK"
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _grade_lower(value, levels):
    if levels == None or len(levels) < 2:
        return "OK"
    warn, crit = levels[0], levels[1]
    if value == None:
        return "OK"
    if value <= crit:
        return "CRIT"
    if value <= warn:
        return "WARN"
    return "OK"

def _build_command(endpoint, standard):
    args = ["check_tcp_cert"]
    address = endpoint.get("address", "")
    port = endpoint.get("port")
    if port == None:
        port = standard.get("port")
    portstr = str(port) if port != None else ""
    args = args + ["--hostname", address]
    if portstr != "":
        args = args + ["--port", portstr]
    indiv = endpoint.get("individual_settings")
    settings = indiv if indiv != None else standard
    conn = settings.get("connection")
    if conn != None and conn != "":
        args = args + ["--connection-type", conn]
    rt = settings.get("response_time")
    if rt != None and len(rt) == 2:
        lvl = rt[0]
        if lvl == "fixed":
            w = rt[1][0] if len(rt[1]) > 0 else 0
            c = rt[1][1] if len(rt[1]) > 1 else 0
            args = args + ["--response-time", str(_round3(w)), str(_round3(c))]
    validity = settings.get("validity")
    if validity != None:
        remaining = validity.get("remaining")
        if remaining != None and len(remaining) == 2:
            lvl = remaining[0]
            if lvl == "fixed":
                w = remaining[1][0] if len(remaining[1]) > 0 else 0
                c = remaining[1][1] if len(remaining[1]) > 1 else 0
                args = args + ["--not-after", str(_round0(w)), str(_round0(c))]
        maximum = validity.get("maximum")
        if maximum != None:
            day = _day_seconds()
            maxdays = maximum / day
            args = args + ["--max-validity", str(_round0(maxdays))]
        if validity.get("self_signed") == True:
            args = args + ["--allow-self-signed"]
    details = settings.get("cert_details")
    if details != None:
        serial = details.get("serialnumber")
        if serial != None and serial != "":
            args = args + ["--serial", serial]
        sig = details.get("signature_algorithm")
        if sig != None and len(sig) >= 2:
            args = args + ["--signature-algorithm", sig[1]]
        issuer = details.get("issuer")
        if issuer != None:
            cn = issuer.get("common_name")
            if cn != None and cn != "":
                args = args + ["--issuer-cn", cn]
            org = issuer.get("organization")
            if org != None and org != "":
                args = args + ["--issuer-o", org]
            ou = issuer.get("org_unit")
            if ou != None and ou != "":
                args = args + ["--issuer-ou", ou]
            st = issuer.get("state")
            if st != None and st != "":
                args = args + ["--issuer-st", st]
            co = issuer.get("country")
            if co != None and co != "":
                args = args + ["--issuer-c", co]
        subject = details.get("subject")
        if subject != None:
            cn = subject.get("common_name")
            if cn != None and cn != "":
                args = args + ["--subject-cn", cn]
            org = subject.get("organization")
            if org != None and org != "":
                args = args + ["--subject-o", org]
            ou = subject.get("org_unit")
            if ou != None and ou != "":
                args = args + ["--subject-ou", ou]
            pk = subject.get("pubkey_algorithm")
            if pk != None and len(pk) >= 1:
                args = args + ["--pubkey-algorithm", pk[0]]
            ps = subject.get("pubkeysize")
            if ps != None and ps != "":
                args = args + ["--pubkey-size", ps]
        alts = details.get("altnames")
        if alts != None:
            for alt in alts:
                if alt != None and alt != "":
                    args = args + ["--subject-alt-names", alt]
    return args

def _parse_output(stdout):
    days_left = None
    response = None
    level = "OK"
    msg = ""
    lines = _split_lines(stdout)
    for line in lines:
        ls = line.strip()
        if ls == "":
            continue
        if ls.startswith("CRITICAL"):
            level = "CRIT"
        elif ls.startswith("WARNING"):
            level = "WARN"
        elif ls.startswith("OK"):
            level = "OK"
        elif ls.startswith("UNKNOWN"):
            level = "UNKNOWN"
        msg = ls
        idx = ls.find("response_time=")
        if idx >= 0:
            rest = ls[idx + len("response_time="):]
            sp = rest.find("s")
            token = rest[:sp] if sp >= 0 else rest
            response = _to_float(token)
        idx = ls.find("not_after=")
        if idx >= 0:
            rest = ls[idx + len("not_after="):]
            sp = rest.find(";")
            token = rest[:sp] if sp >= 0 else rest
            token = token.strip()
            if token.isdigit():
                days_left = float(token)
    return level, msg, days_left, response

def main(ctx, params):
    is_disc = params.get("_discover")
    standard = params.get("standard_settings", {})
    if standard == None:
        standard = {}
    standard_port = standard.get("port", 443)
    standard = dict(standard)
    standard["port"] = standard_port
    connections = params.get("connections", [])
    if connections == None:
        connections = []

    if is_disc:
        probe = ctx.run(["check_tcp_cert", "--help"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "check_tcp_cert not available", "data": {"discovery": []}}
        items = []
        for conn in connections:
            addr = conn.get("address", "")
            if addr == "":
                continue
            name = conn.get("service_name", {})
            prefix = name.get("prefix", "auto")
            nm = name.get("name", addr)
            full = ("CERT " if prefix == "auto" else "") + nm
            indiv = conn.get("individual_settings")
            s = indiv if indiv != None else standard
            levels = {}
            validity = s.get("validity")
            if validity != None and validity.get("remaining") != None:
                rem = validity.get("remaining")
                if rem[0] == "fixed":
                    levels["warn"] = rem[1][0] if len(rem[1]) > 0 else 0
                    levels["crit"] = rem[1][1] if len(rem[1]) > 1 else 0
            rt = s.get("response_time")
            if rt != None:
                if rt[0] == "fixed":
                    levels["warn_response"] = rt[1][0] if len(rt[1]) > 0 else 0
                    levels["crit_response"] = rt[1][1] if len(rt[1]) > 1 else 0
            items.append({
                "item": full,
                "params": levels,
                "metrics": ["response_time", "remaining_days"],
            })
        return {"changed": False, "msg": "discovered %d cert services" % len(items), "data": {"discovery": items}}

    item = params.get("item", "")
    target = None
    for conn in connections:
        name = conn.get("service_name", {})
        prefix = name.get("prefix", "auto")
        nm = name.get("name", conn.get("address", ""))
        full = ("CERT " if prefix == "auto" else "") + nm
        if full == item:
            target = conn
            break
    if target == None:
        for conn in connections:
            if conn.get("address", "") == item:
                target = conn
                break

    if target == None:
        return {"changed": False, "msg": "no cert endpoint configured for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    indiv = target.get("individual_settings")
    settings = indiv if indiv != None else standard

    argv = _build_command(target, standard)
    res = ctx.run(argv, mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "check_tcp_cert binary not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 and res.stdout == "":
        return {"changed": False, "msg": "cert check failed for " + item + ": " + (res.stderr or "rc=%d" % res.rc),
                "data": {"state": "CRIT", "metrics": {}, "details": res.stderr or ""}}

    level, msg, days_left, response = _parse_output(res.stdout)
    if days_left == None and response == None:
        if level == "OK" and msg == "":
            msg = "cert check returned no readable perfdata"
            level = "UNKNOWN"

    metrics = {}
    if response != None:
        metrics["response_time"] = response
    if days_left != None:
        metrics["remaining_days"] = days_left

    final = level
    rt_levels = settings.get("response_time")
    validity = settings.get("validity")
    rem_levels = None
    if validity != None:
        rl = validity.get("remaining")
        if rl != None:
            rem_levels = rl
    if response != None and rt_levels != None:
        g = _grade_upper(response, rt_levels[1] if rt_levels[0] == "fixed" else None)
        if g == "CRIT":
            final = "CRIT"
        elif g == "WARN" and final != "CRIT":
            final = "WARN"
    if days_left != None and rem_levels != None:
        g = _grade_lower(days_left, rem_levels[1] if rem_levels[0] == "fixed" else None)
        if g == "CRIT":
            final = "CRIT"
        elif g == "WARN" and final != "CRIT":
            final = "WARN"

    if level == "UNKNOWN":
        final = "UNKNOWN"

    summary = msg
    if not summary:
        summary = item + " cert check"

    return {"changed": False, "msg": summary,
            "data": {"state": final, "metrics": metrics, "details": res.stdout or ""}}