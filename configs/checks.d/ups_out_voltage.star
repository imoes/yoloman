def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

def _is_ups_present(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Ovqn", "-t", "3", "-r", "1",
                   host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    oid = res.stdout.strip()
    if not oid:
        return None
    ups_oids = [
        ".1.3.6.1.4.1.232.165.3",
        ".1.3.6.1.4.1.476.1.42",
        ".1.3.6.1.4.1.534.1",
        ".1.3.6.1.4.1.935",
        ".1.3.6.1.4.1.8072.3.2.10",
        ".1.3.6.1.4.1.2254.2.5",
        ".1.3.6.1.4.1.12551.4.0",
        ".1.3.6.1.4.1.850",
        ".1.3.6.1.4.1.43943",
        ".1.3.6.1.4.1.4555.1.1.7",
        ".1.3.6.1.4.1.42610.1.4.4",
        ".1.3.6.1.2.1.33",
        ".1.3.6.1.4.1.534.2",
        ".1.3.6.1.4.1.5491",
        ".1.3.6.1.4.1.705.1",
        ".1.3.6.1.4.1.818.1.100.1",
        ".1.3.6.1.2.1.514.1",
    ]
    for u in ups_oids:
        if oid == u:
            return oid
        if oid.startswith(u + "."):
            return oid
        if u.startswith(".1.3.6.1.4.1.850") and oid.startswith(".1.3.6.1.4.1.850"):
            return oid
        if u.startswith(".1.3.6.1.4.1.935") and oid.startswith(".1.3.6.1.4.1.935"):
            return oid
        if u.startswith(".1.3.6.1.2.1.33") and oid.startswith(".1.3.6.1.2.1.33"):
            return oid
        if u.startswith(".1.3.6.1.4.1.534.2") and oid.startswith(".1.3.6.1.4.1.534.2"):
            return oid
        if u.startswith(".1.3.6.1.4.1.5491") and oid.startswith(".1.3.6.1.4.1.5491"):
            return oid
        if u.startswith(".1.3.6.1.4.1.705.1") and oid.startswith(".1.3.6.1.4.1.705.1"):
            return oid
        if u.startswith(".1.3.6.1.4.1.818.1.100.1") and oid.startswith(".1.3.6.1.4.1.818.1.100.1"):
            return oid
    return None

def _discover(ctx, params):
    if _is_ups_present(ctx, params) == None:
        return {"changed": False, "msg": "no UPS detected", "data": {"discovery": []}}
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-t", "3", "-r", "1",
                   host, ".1.3.6.1.2.1.33.1.4.4.1.2"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no UPS out voltage data", "data": {"discovery": []}}
    discovery = []
    seen = []
    for line in res.stdout.splitlines():
        parts = line.strip().split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        suffix = oid[len(".1.3.6.1.2.1.33.1.4.4.1.2") + 1:]
        if suffix == "":
            continue
        if suffix in seen:
            continue
        seen.append(suffix)
        discovery.append({"item": suffix, "params": {"levels_lower": (210.0, 180.0)},
                          "metrics": ["out_voltage"]})
    return {"changed": False, "msg": "discovered %d phases" % len(discovery),
            "data": {"discovery": discovery}}

def _check(ctx, params):
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if _is_ups_present(ctx, params) == None:
        return {"changed": False, "msg": "no UPS detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "3", "-r", "1",
                   host, ".1.3.6.1.2.1.33.1.4.4.1.2." + item], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no UPS out voltage for phase %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    if not raw:
        return {"changed": False, "msg": "no UPS out voltage for phase %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = _parse_voltage(raw)
    if value == None:
        return {"changed": False, "msg": "cannot parse out voltage: %s" % raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels_lower = params.get("levels_lower", (210.0, 180.0))
    warn = levels_lower[0]
    crit = levels_lower[1]
    state = "OK"
    if value <= crit:
        state = "CRIT"
    elif value <= warn:
        state = "WARN"
    return {"changed": False, "msg": "Out voltage: %fV" % value,
            "data": {"state": state, "metrics": {"out_voltage": value}, "details": ""}}

def _parse_voltage(s):
    s = s.strip()
    if s.startswith(": ") or s.startswith(":"):
        s = s[2:] if s.startswith(": ") else s[1:]
        s = s.strip()
    if s.startswith('"') and s.endswith('"'):
        s = s[1:-1]
        s = s.strip()
    if not s:
        return None
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    elif s.startswith("+"):
        s = s[1:]
    digits = ""
    dot_seen = False
    for ch in s:
        if ch.isdigit():
            digits = digits + ch
        elif ch == "." and not dot_seen:
            digits = digits + ch
            dot_seen = True
        else:
            break
    if digits == "" or digits == ".":
        return None
    v = float(digits)
    if neg:
        v = -v
    return v