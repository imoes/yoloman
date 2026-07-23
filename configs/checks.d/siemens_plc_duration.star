def _pow10(n):
    r = 1.0
    for _ in range(n):
        r = r * 10.0
    return r

def _parse_float(s):
    s = s.strip()
    neg = s.startswith("-")
    t = s[1:] if neg else s
    parts = t.split(".", 1)
    if len(parts) == 2:
        ok = parts[0].isdigit() and parts[1].isdigit()
    else:
        ok = len(parts) == 1 and parts[0].isdigit()
    if not ok:
        return 0.0
    if len(parts) == 2:
        v = float(int(parts[0])) + float(int(parts[1])) / _pow10(len(parts[1]))
    else:
        v = float(int(parts[0]))
    return -v if neg else v

def _format_duration(seconds):
    s = int(seconds)
    if s < 60:
        return "%d seconds" % s
    m = s // 60
    if m < 60:
        return "%d minutes %d seconds" % (m, s % 60)
    h = m // 60
    if h < 24:
        return "%d hours %d minutes" % (h, m % 60)
    d = h // 24
    return "%d days %d hours" % (d, h % 24)

def main(ctx, params):
    data_file = params.get("data_file", "/var/lib/agentic/siemens_plc.txt")

    if not ctx.file_exists(data_file):
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "data file not found: " + data_file,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    content = ctx.file_read(data_file)

    if params.get("_discover"):
        seen = {}
        out = []
        for line in content.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            kind = parts[1]
            if kind.startswith("hours") or kind.startswith("seconds"):
                item_name = parts[0] + " " + parts[2]
                if item_name not in seen:
                    seen[item_name] = True
                    out.append({
                        "item": item_name,
                        "params": {},
                        "metrics": [kind],
                    })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    duration_levels = params.get("duration")

    for line in content.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        kind = parts[1]
        if not (kind.startswith("hours") or kind.startswith("seconds")):
            continue
        if parts[0] + " " + parts[2] != item:
            continue

        value_f = _parse_float(parts[-1])
        if kind.startswith("hours"):
            seconds = value_f * 3600.0
        else:
            seconds = value_f

        state = "OK"
        detail = ""
        if duration_levels != None:
            warn = float(duration_levels[0])
            crit = float(duration_levels[1])
            if seconds >= crit:
                state = "CRIT"
                detail = " (crit >= %s)" % _format_duration(crit)
            elif seconds >= warn:
                state = "WARN"
                detail = " (warn >= %s)" % _format_duration(warn)

        return {
            "changed": False,
            "msg": "%s: %s%s" % (item, _format_duration(seconds), detail),
            "data": {
                "state": state,
                "metrics": {kind: seconds},
                "details": "",
            },
        }

    return {
        "changed": False,
        "msg": "item not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }