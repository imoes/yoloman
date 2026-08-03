def _is_number(s):
    if len(s) == 0:
        return False
    if s[0] == "-":
        s = s[1:]
    if len(s) == 0:
        return False
    i = 0
    for c in s:
        if c < "0" or c > "9":
            if i != 0 or c != ".":
                return False
        i += 1
    return True

def _to_float(s):
    if s == "-":
        return 0.0
    if not _is_number(s):
        return 0.0
    return float(s)

def _parse_line(line):
    f = line.split()
    if len(f) < 5:
        return None
    name = f[0]
    unit_type = f[1]
    status = f[2]
    complete = f[3]
    rest = f[4:]
    size = 0.0
    if len(rest) >= 3:
        candidate = rest[1]
        if _is_number(candidate):
            size = float(candidate)
        else:
            size = _to_float(rest[0])
    elif len(rest) >= 1:
        size = _to_float(rest[0])
    return name, unit_type, status, complete, size

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["/usr/sbin/tw_cli", "show", "/units"], mutates=False)
        if probe.rc != 0 or probe.skipped:
            return {"changed": False, "msg": "3ware not installed", "data": {"discovery": []}}
        discovery = []
        for line in probe.stdout.splitlines():
            parsed = _parse_line(line)
            if parsed == None:
                continue
            name = parsed[0]
            discovery.append({"item": name, "params": {}, "metrics": []})
        if len(discovery) == 0:
            return {"changed": False, "msg": "3ware not installed", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered %d units" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    probe = ctx.run(["/usr/sbin/tw_cli", "show", "/units"], mutates=False)
    if probe.rc != 0 or probe.skipped:
        return {"changed": False, "msg": "tw_cli not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target = None
    for line in probe.stdout.splitlines():
        parsed = _parse_line(line)
        if parsed == None:
            continue
        if parsed[0] == item:
            target = parsed
            break

    if target == None:
        return {"changed": False, "msg": "no 3ware unit " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name, unit_type, status, complete, size = target
    status_upper = status.upper()
    if status_upper in ("OK", "VERIFYING"):
        state = "OK"
    elif status_upper in ("INITIALIZING", "VERIFY-PAUSED", "REBUILDING"):
        state = "WARN"
    else:
        state = "CRIT"

    details = "Type: %s\nSize: %sGB" % (unit_type, str(size))
    if complete != "-":
        details = details + "\nComplete: %s%%" % complete

    return {"changed": False, "msg": status, "data": {"state": state, "metrics": {}, "details": details}}