# apc_symmetra_output.star — read-only translation of Checkmk's apc_symmetra_output check
# Monitors APC Symmetra output phase voltage/current/load via SNMP.

def _to_float(s):
    out = s.strip()
    if len(out) == 0:
        return None
    neg = False
    i = 0
    if out[0] == "-":
        neg = True
        i = 1
    digits = False
    has_dot = False
    for j in range(i, len(out)):
        c = out[j]
        if c >= "0" and c <= "9":
            digits = True
        elif c == "." and not has_dot:
            has_dot = True
        else:
            return None
    if not digits:
        return None
    val = float(out)
    if neg:
        val = -val
    return val

def _level_state(value, params_tuple):
    if params_tuple == None:
        return "OK"
    warn = params_tuple[0]
    crit = params_tuple[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        sys_oid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_oid.rc != 0 or sys_oid.rc == 127:
            return {"changed": False, "msg": "APC Symmetra not detected (no SNMP)",
                    "data": {"discovery": [], "host_labels": {}}}
        sys_val = sys_oid.stdout.strip()
        if not sys_val.startswith(".1.3.6.1.4.1.318"):
            return {"changed": False, "msg": "APC Symmetra not detected",
                    "data": {"discovery": [], "host_labels": {}}}

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.318.1.1.1.4.2"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "APC Symmetra output not found",
                    "data": {"discovery": [], "host_labels": {"cmk/os_family": "linux"}}}

        indices = {}
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            suffix = oid[len(".1.3.6.1.4.1.318.1.1.1.4.2") + 1:]
            dot = suffix.find(".")
            idx = suffix if dot < 0 else suffix[:dot]
            if idx == "":
                continue
            indices[idx] = suffix

        discovery = []
        for idx in sorted(indices.keys()):
            discovery.append({
                "item": "Output",
                "params": {"voltage": (220, 220)},
                "metrics": ["voltage", "current", "power"],
            })

        return {"changed": False,
                "msg": "discovered %d output phases" % len(discovery),
                "data": {"discovery": discovery,
                         "host_labels": {"cmk/os_family": "linux"}}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    v = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                 ".1.3.6.1.4.1.318.1.1.1.4.2.1.0"], mutates=False)
    c = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                 ".1.3.6.1.4.1.318.1.1.1.4.2.4.0"], mutates=False)
    l = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                 ".1.3.6.1.4.1.318.1.1.1.4.2.3.0"], mutates=False)

    voltage = _to_float(v.stdout) if v.rc == 0 else None
    current = _to_float(c.stdout) if c.rc == 0 else None
    power = _to_float(l.stdout) if l.rc == 0 else None

    if voltage == None:
        return {"changed": False,
                "msg": "no output voltage reading available for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    states = []

    if voltage != None:
        metrics["voltage"] = voltage
        vl = params.get("voltage", (220, 220))
        s = _level_state(voltage, vl)
        states.append(("voltage", voltage, s, vl))

    if current != None:
        metrics["current"] = current
        cl = params.get("current")
        s = _level_state(current, cl)
        states.append(("current", current, s, cl))

    if power != None:
        metrics["power"] = power
        pl = params.get("output_load")
        s = _level_state(power, pl)
        states.append(("output_load", power, s, pl))

    worst = "OK"
    for (_, _, s, _) in states:
        if s == "CRIT":
            worst = "CRIT"
        elif s == "WARN" and worst != "CRIT":
            worst = "WARN"

    parts = []
    if voltage != None:
        parts.append("V=%f" % voltage)
    if current != None:
        parts.append("A=%f" % current)
    if power != None:
        parts.append("W=%f" % power)
    summary = ", ".join(parts) if parts else "no readings"

    return {"changed": False,
            "msg": "Phase %s %s: %s" % (item, worst, summary),
            "data": {"state": worst, "metrics": metrics, "details": summary}}