# Siemens PLC info check — reads the <<<siemens_plc>>> agent section output
# supplied via the host (params["section"] when provided, otherwise probed).
# The Checkmk SIEMENS_PLC special agent already fetched PLC data over the
# network; we only parse what it returned. This is read-only.

def _is_missing(v):
    return v == None or v == [] or v == {}

def _render_time_offset(seconds):
    # Human-readable duration, mirroring Checkmk render.time_offset.
    s = int(seconds)
    if s < 60:
        return "%ds" % s
    m = s / 60
    if m < 60:
        return "%dm" % int(m)
    h = m / 60
    return "%dh %dm" % (int(h), int(m % 60))

def _parse_section(ctx):
    # Prefer an explicitly passed section (the agent already ran the PLC query).
    raw = ctx.params.get("section") if hasattr(ctx, "params") else None
    if _is_missing(raw):
        raw = ctx.get("section", None) if hasattr(ctx, "get") else None
    if _is_missing(raw):
        return []
    if type(raw) == "string":
        return [line.split() for line in raw.splitlines() if line.strip()]
    return raw

def _find_lines(section, kind, item):
    # kind: "temp"|"flag"|"text"|"hours"|"seconds"|"counter"
    matches = []
    for line in section:
        if not line or len(line) < 3:
            continue
        if kind in ("hours", "seconds"):
            ok = line[1].startswith("hours") or line[1].startswith("seconds")
        elif kind == "counter":
            ok = line[1].startswith("counter")
        else:
            ok = line[1] == kind
        if ok and "%s %s" % (line[0], line[2]) == item:
            matches.append(line)
    return matches

def _grade_levels(value, warn, crit, upper=True):
    if crit != None and ((upper and value >= crit) or (not upper and value <= crit)):
        return "CRIT"
    if warn != None and ((upper and value >= warn) or (not upper and value <= warn)):
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        section = _parse_section(ctx)
        discovery = []
        seen = {}
        for line in section:
            if not line or len(line) < 3:
                continue
            key = "%s %s" % (line[0], line[2])
            if line[1] == "temp":
                if key not in seen:
                    seen[key] = True
                    discovery.append({"item": key, "params": {"levels": (70.0, 80.0)}, "metrics": ["temperature"]})
            elif line[1] == "flag":
                if key not in seen:
                    seen[key] = True
                    discovery.append({"item": key, "params": {"expected_state": False}, "metrics": []})
            elif line[1].startswith("hours") or line[1].startswith("seconds"):
                if key not in seen:
                    seen[key] = True
                    mname = "duration_seconds"
                    discovery.append({"item": key, "params": {"duration": {"levels": None}}, "metrics": [mname]})
            elif line[1].startswith("counter"):
                if key not in seen:
                    seen[key] = True
                    discovery.append({"item": key, "params": {"levels": None}, "metrics": ["counter"]})
            elif line[1] == "text":
                if key not in seen:
                    seen[key] = True
                    discovery.append({"item": key, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _parse_section(ctx)
    if not section:
        # No PLC data available on this host -> not applicable.
        return {"changed": False, "msg": "no Siemens PLC data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Determine which sub-check this item belongs to.
    which = params.get("_check", "info")
    if which == "temp":
        lines = _find_lines(section, "temp", item)
        if not lines:
            return {"changed": False, "msg": "no such temperature item: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        temp = float(lines[0][-1])
        warn = 80.0
        crit = 90.0
        lv = params.get("levels")
        if lv != None and type(lv) == "list" and len(lv) >= 2:
            warn = float(lv[0]); crit = float(lv[1])
        elif params.get("warn") != None:
            warn = float(params.get("warn"))
        if params.get("crit") != None:
            crit = float(params.get("crit"))
        state = _grade_levels(temp, warn, crit, upper=True)
        return {"changed": False,
                "msg": "%s %f C" % (item, temp),
                "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}

    if which == "flag":
        lines = _find_lines(section, "flag", item)
        if not lines:
            return {"changed": False, "msg": "no such flag item: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        expected = params.get("expected_state", False)
        flag_on = lines[0][-1] == "True"
        if flag_on:
            state = "OK" if expected else "CRIT"
            summary = "On"
        else:
            state = "CRIT" if expected else "OK"
            summary = "Off"
        return {"changed": False, "msg": "%s %s" % (item, summary),
                "data": {"state": state, "metrics": {}, "details": ""}}

    if which == "duration":
        lines = _find_lines(section, "seconds", item) + _find_lines(section, "hours", item)
        if not lines:
            return {"changed": False, "msg": "no such duration item: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        line = lines[0]
        raw = float(line[-1])
        seconds = raw * 3600 if line[1].startswith("hours") else raw
        dur_params = params.get("duration")
        warn = None; crit = None
        if dur_params != None and type(dur_params) == "dict":
            lv = dur_params.get("levels")
            if lv != None and type(lv) == "list" and len(lv) >= 2:
                warn = float(lv[0]); crit = float(lv[1])
        state = _grade_levels(seconds, warn, crit, upper=True)
        return {"changed": False,
                "msg": "%s %s" % (item, _render_time_offset(seconds)),
                "data": {"state": state, "metrics": {"duration_seconds": seconds}, "details": ""}}

    if which == "counter":
        lines = _find_lines(section, "counter", item)
        if not lines:
            return {"changed": False, "msg": "no such counter item: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        value = int(lines[0][-1])
        lv = params.get("levels")
        warn = None; crit = None
        if lv != None and type(lv) == "list" and len(lv) >= 2:
            warn = float(lv[0]); crit = float(lv[1])
        state = _grade_levels(value, warn, crit, upper=True)
        return {"changed": False,
                "msg": "%s %d" % (item, value),
                "data": {"state": state, "metrics": {"counter": float(value)}, "details": ""}}

    # default: info (text)
    lines = _find_lines(section, "text", item)
    if not lines:
        return {"changed": False, "msg": "no such info item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    text = lines[0][-1]
    return {"changed": False, "msg": "%s %s" % (item, text),
            "data": {"state": "OK", "metrics": {}, "details": ""}}