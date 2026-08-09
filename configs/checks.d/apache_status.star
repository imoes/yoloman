# checkmk.apache_status -> read-only Starlark check module (yolo-man agent)
# Apache server-status monitor.
# READ-ONLY: never mutates, always changed=False.

_FIELD_CASTER = {
    "Uptime": "int",
    "IdleWorkers": "int",
    "BusyWorkers": "int",
    "OpenSlots": "int",
    "TotalSlots": "int",
    "Total Accesses": "int",
    "CPULoad": "float",
    "Total kBytes": "float",
    "ReqPerSec": "float",
    "BytesPerReq": "float",
    "BytesPerSec": "float",
    "Scoreboard": "str",
    "ConnsTotal": "int",
    "ConnsAsyncWriting": "int",
    "ConnsAsyncKeepAlive": "int",
    "ConnsAsyncClosing": "int",
    "BusyServers": "int",
    "IdleServers": "int",
}

_CHECK_LEVEL_ENTRIES = [
    ("Uptime", "Uptime"),
    ("IdleWorkers", "Idle workers"),
    ("BusyWorkers", "Busy workers"),
    ("TotalSlots", "Total slots"),
    ("OpenSlots", "Open slots"),
    ("Total Accesses", "Total access"),
    ("CPULoad", "CPU load"),
    ("Total kBytes", "Total kB"),
    ("ReqPerSec", "Requests per second"),
    ("BytesPerReq", "Bytes per request"),
    ("BytesPerSec", "Bytes per second"),
    ("ConnsTotal", "Total connections"),
    ("ConnsAsyncWriting", "Async writing connections"),
    ("ConnsAsyncKeepAlive", "Async keep alive connections"),
    ("ConnsAsyncClosing", "Async closing connections"),
    ("BusyServers", "Busy servers"),
    ("IdleServers", "Idle servers"),
]

_SCOREBOARD_LABEL_MAP = {
    "Waiting": "_",
    "StartingUp": "S",
    "ReadingRequest": "R",
    "SendingReply": "W",
    "Keepalive": "K",
    "DNS": "D",
    "Closing": "C",
    "Logging": "L",
    "Finishing": "G",
    "IdleCleanup": "O",
}


def _to_int(value):
    if value == "" or value == None:
        return None
    neg = ""
    s = value
    if s.startswith("-"):
        neg = "-"
        s = s[1:]
    if not s.isdigit():
        return None
    return int(neg + s) if neg == "-" else int(s)


def _to_float(value):
    if value == "" or value == None:
        return None
    # Manual parse: optional sign, digits, optional .digits
    s = value
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    elif s.startswith("+"):
        s = s[1:]
    if s == "":
        return None
    dot = s.find(".")
    if dot < 0:
        if not s.isdigit():
            return None
        f = int(s)
        if neg:
            f = -f
        return float(f)
    intpart = s[:dot]
    fracpart = s[dot + 1:]
    if intpart == "" and fracpart == "":
        return None
    ok = True
    if intpart != "":
        for ch in intpart:
            if not (("0" <= ch) and (ch <= "9")):
                ok = False
                break
    if not ok:
        return None
    if fracpart != "":
        for ch in fracpart:
            if not (("0" <= ch) and (ch <= "9")):
                ok = False
                break
    if not ok:
        return None
    # Build float via string since we have json.encode/decode available
    sign = "-" if neg else ""
    # Use int multiplication to avoid float string issues; fallback to 0
    ip = int(intpart) if intpart != "" else 0
    fp = 0
    fdiv = 1
    for ch in fracpart:
        fp = fp * 10 + (ord(ch) - ord("0"))
        fdiv = fdiv * 10
    result = float(ip) + float(fp) / float(fdiv)
    if neg:
        result = -result
    return result


def _cast(label, value):
    caster = _FIELD_CASTER.get(label)
    if caster == None:
        return None, False
    if caster == "int":
        v = _to_int(value)
        if v == None:
            return None, False
        return v, True
    if caster == "float":
        v = _to_float(value)
        if v == None:
            return None, False
        return v, True
    if caster == "str":
        return value, True
    return None, False


def _parse_status(text):
    data = {}
    item = None
    scoreboard = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("Scoreboard:"):
            scoreboard = line[len("Scoreboard:"):].strip()
            continue
        if line.startswith("ServerVersion") or line.startswith("ServerMPM"):
            continue
        idx = line.find(":")
        if idx < 0:
            continue
        label = line[:idx].strip()
        value = line[idx + 1:].strip()
        casted, ok = _cast(label, value)
        if not ok:
            continue
        if label == "Scoreboard":
            scoreboard = value
            item = "localhost"
            continue
        data[label] = casted
        item = "localhost"
    if scoreboard != None:
        sb = scoreboard
        st = data
        for stat_label, key in _SCOREBOARD_LABEL_MAP.items():
            st["State_" + stat_label] = sb.count(key)
        st["OpenSlots"] = sb.count(".")
        if "OpenSlots" in st and "IdleWorkers" in st and "BusyWorkers" in st:
            st["TotalSlots"] = st["OpenSlots"] + st["IdleWorkers"] + st["BusyWorkers"]
    return data, item, scoreboard


def _grade_upper(value, levels):
    if levels == None:
        return "OK"
    warn = levels[0] if len(levels) >= 1 else None
    crit = levels[1] if len(levels) >= 2 else None
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"


def _grade_lower(value, levels):
    if levels == None:
        return "OK"
    warn = levels[0] if len(levels) >= 1 else None
    crit = levels[1] if len(levels) >= 2 else None
    if crit != None and value <= crit:
        return "CRIT"
    if warn != None and value <= warn:
        return "WARN"
    return "OK"


def _levels_for(key, params):
    if key in params:
        return params[key]
    return None


def _scoreboard_notice(data):
    states = []
    for stat_label in _SCOREBOARD_LABEL_MAP:
        key = "State_" + stat_label
        value = data.get(key, 0)
        if value > 0:
            states.append(stat_label + ": " + str(value))
    if states:
        return "Scoreboard states:\n  " + "\n  ".join(states)
    return "Scoreboard states: (none)"


def _format_timespan(seconds):
    s = int(seconds)
    days = s // 86400
    hours = (s % 86400) // 3600
    minutes = (s % 3600) // 60
    secs = s % 60
    parts = []
    if days > 0:
        parts.append(str(days) + "d")
    if hours > 0:
        parts.append(str(hours) + "h")
    if minutes > 0:
        parts.append(str(minutes) + "m")
    parts.append(str(secs) + "s")
    return " ".join(parts)


def _is_tool_available(ctx, names):
    for n in names:
        res = ctx.run([n, "--version"], mutates=False)
        if res.rc == 0:
            return True
    return False


def _fetch_status(ctx, status_url):
    res = ctx.run(["curl", "-fsS", status_url], mutates=False)
    if res.rc != 0:
        res2 = ctx.run(["wget", "-q", "-O", "-", status_url], mutates=False)
        if res2.rc == 0:
            return res2.stdout
        return None
    return res.stdout


def main(ctx, params):
    if params.get("_discover"):
        if not _is_tool_available(ctx, ["apachectl", "httpd", "apache2ctl", "curl", "wget"]):
            return {"changed": False, "msg": "Apache/curl not found",
                    "data": {"discovery": []}}
        status_url = params.get("status_url", "http://localhost/server-status?auto")
        out = _fetch_status(ctx, status_url)
        if out == None or out == "":
            return {"changed": False, "msg": "Apache status not reachable",
                    "data": {"discovery": []}}
        data, item, scoreboard = _parse_status(out)
        if item == None and scoreboard == None and len(data) == 0:
            return {"changed": False, "msg": "Apache status empty",
                    "data": {"discovery": []}}
        metrics = []
        for key, _label in _CHECK_LEVEL_ENTRIES:
            metrics.append(key.replace(" ", "_"))
        for stat_label in _SCOREBOARD_LABEL_MAP:
            metrics.append("State_" + stat_label)
        return {"changed": False, "msg": "discovered apache_status",
                "data": {"discovery": [
                    {"item": item if item != None else "localhost",
                     "params": {}, "metrics": metrics},
                ]}}

    item = params.get("item", "")
    status_url = params.get("status_url", "http://localhost/server-status?auto")
    out = _fetch_status(ctx, status_url)
    if out == None or out == "":
        return {"changed": False, "msg": "Apache status not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data, parse_item, scoreboard = _parse_status(out)
    if item == None or item == "":
        item = parse_item if parse_item != None else "localhost"
    if item.endswith(":None"):
        item = item[:-5]
    if len(data) == 0 and scoreboard == None:
        return {"changed": False, "msg": "no Apache status data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    max_state = "OK"
    summary_parts = []
    notices = []

    for key, label in _CHECK_LEVEL_ENTRIES:
        if key not in data:
            continue
        value = data[key]
        levels = _levels_for(key, params)
        if key == "OpenSlots":
            state = _grade_lower(value, levels)
        else:
            state = _grade_upper(value, levels)
        if state == "WARN" and max_state == "OK":
            max_state = "WARN"
        if state == "CRIT":
            max_state = "CRIT"
        metric_name = key.replace(" ", "_")
        if type(value) == "int" or type(value) == "float":
            metrics[metric_name] = value
        if key == "Uptime":
            summary_parts.append(label + ": " + _format_timespan(value))
        elif type(value) == "int":
            summary_parts.append(label + ": " + str(int(value)))
        elif type(value) == "float":
            summary_parts.append(label + ": " + str(value))
        else:
            summary_parts.append(label + ": " + str(value))

    for stat_label in _SCOREBOARD_LABEL_MAP:
        skey = "State_" + stat_label
        value = data.get(skey, 0)
        metrics[skey] = value
    notices.append(_scoreboard_notice(data))

    summary = "; ".join(summary_parts)
    if scoreboard != None:
        summary = summary + " | Scoreboard: " + scoreboard

    return {"changed": False,
            "msg": summary,
            "data": {"state": max_state, "metrics": metrics,
                     "details": "\n".join(notices)}}