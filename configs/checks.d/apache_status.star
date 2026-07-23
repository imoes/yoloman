_SCOREBOARD_LABELS = [
    "Waiting", "StartingUp", "ReadingRequest", "SendingReply",
    "Keepalive", "DNS", "Closing", "Logging", "Finishing", "IdleCleanup",
]

_SCOREBOARD_CHARS = {
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

_INT_FIELDS = [
    "Uptime", "IdleWorkers", "BusyWorkers", "OpenSlots", "TotalSlots",
    "Total Accesses", "ConnsTotal", "ConnsAsyncWriting", "ConnsAsyncKeepAlive",
    "ConnsAsyncClosing", "BusyServers", "IdleServers",
]

_FLOAT_FIELDS = ["CPULoad", "Total kBytes", "ReqPerSec", "BytesPerReq", "BytesPerSec"]

_CHECK_LEVEL_ENTRIES = [
    ("Uptime", "Uptime"),
    ("IdleWorkers", "Idle workers"),
    ("BusyWorkers", "Busy workers"),
    ("TotalSlots", "Total slots"),
    ("OpenSlots", "Open slots"),
    ("ReqPerSec", "Requests per second"),
    ("BytesPerReq", "Bytes per request"),
    ("BytesPerSec", "Bytes per second"),
    ("CPULoad", "CPU load"),
    ("ConnsTotal", "Total connections"),
    ("ConnsAsyncWriting", "Async writing connections"),
    ("ConnsAsyncKeepAlive", "Async keep alive connections"),
    ("ConnsAsyncClosing", "Async closing connections"),
    ("BusyServers", "Busy servers"),
    ("IdleServers", "Idle servers"),
]

# Matches Checkmk notice_only=False keys — shown in summary line
_SUMMARY_KEYS = ["Uptime", "IdleWorkers", "BusyWorkers", "TotalSlots"]

# Thresholds are lower-bound (WARN/CRIT when value drops below)
_LOWER_LEVEL_KEYS = ["OpenSlots"]


def _is_number(s):
    if not s:
        return False
    start = 1 if s[0] == "-" else 0
    if start >= len(s):
        return False
    has_dot = False
    for i in range(start, len(s)):
        c = s[i]
        if c == ".":
            if has_dot:
                return False
            has_dot = True
        elif c < "0" or c > "9":
            return False
    return True


def _parse_status(content):
    data = {}
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        idx = line.find(":")
        if idx < 0:
            continue
        key = line[:idx].strip()
        val = line[idx + 1:].strip()

        if key in _INT_FIELDS:
            data[key] = int(float(val)) if _is_number(val) else 0
        elif key in _FLOAT_FIELDS:
            data[key] = float(val) if _is_number(val) else 0.0
        elif key == "Scoreboard":
            data["Scoreboard"] = val
            for label in _SCOREBOARD_LABELS:
                data["State_" + label] = val.count(_SCOREBOARD_CHARS[label])
            data["OpenSlots"] = val.count(".")

    if "OpenSlots" in data and "IdleWorkers" in data and "BusyWorkers" in data:
        if "TotalSlots" not in data:
            data["TotalSlots"] = (
                data["OpenSlots"] + data["IdleWorkers"] + data["BusyWorkers"]
            )

    return data


def _format_uptime(seconds):
    s = int(seconds)
    h = s // 3600
    m = (s % 3600) // 60
    sec = s % 60
    if h > 0:
        return "%dh %dm %ds" % (h, m, sec)
    if m > 0:
        return "%dm %ds" % (m, sec)
    return "%ds" % sec


def _format_value(key, value):
    if key == "Uptime":
        return _format_uptime(value)
    if key in _FLOAT_FIELDS:
        return "%f" % value
    return "%d" % int(value)


def _apply_levels(state, value, levels, lower):
    if levels == None:
        return state
    warn = levels[0]
    crit = levels[1]
    if lower:
        if value <= crit:
            return "CRIT"
        if value <= warn and state != "CRIT":
            return "WARN"
    else:
        if value >= crit:
            return "CRIT"
        if value >= warn and state != "CRIT":
            return "WARN"
    return state


def _build_argv(scheme, host, port, path, user, password):
    url = "%s://%s:%d%s?auto" % (scheme, host, int(port), path)
    argv = ["curl", "-s", "--max-time", "10", "--insecure", url]
    if user != None and password != None:
        argv = argv + ["--user", user + ":" + password]
    return argv


def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 80)
    path = params.get("path", "/server-status")
    use_ssl = params.get("use_ssl", False)
    user = params.get("user", None)
    password = params.get("password", None)
    scheme = "https" if use_ssl else "http"

    if params.get("_discover"):
        argv = _build_argv(scheme, host, port, path, user, password)
        res = ctx.run(argv, mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "apache status not available",
                    "data": {"discovery": []}}
        data = _parse_status(res.stdout)
        if not data:
            return {"changed": False, "msg": "no data parsed",
                    "data": {"discovery": []}}
        item = "%s:%d" % (host, int(port))
        metrics = []
        for key in _INT_FIELDS:
            if key in data:
                metrics.append(key.replace(" ", "_"))
        for key in _FLOAT_FIELDS:
            if key in data:
                metrics.append(key.replace(" ", "_"))
        for label in _SCOREBOARD_LABELS:
            metrics.append("State_" + label)
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": item, "params": {}, "metrics": metrics}]},
        }

    # Check mode
    item = params.get("item", "")
    if item != "" and ":" in item:
        parts = item.rsplit(":", 1)
        check_host = parts[0]
        check_port = int(parts[1]) if parts[1].isdigit() else int(port)
    elif item != "":
        check_host = item
        check_port = int(port)
    else:
        check_host = host
        check_port = int(port)

    display_item = item if item != "" else ("%s:%d" % (host, int(port)))
    argv = _build_argv(scheme, check_host, check_port, path, user, password)
    res = ctx.run(argv, mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch status from " + display_item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr}}
    if not res.stdout:
        return {"changed": False, "msg": "empty response from " + display_item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = _parse_status(res.stdout)
    if not data:
        return {"changed": False, "msg": "could not parse apache status from " + display_item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    for key, _label in _CHECK_LEVEL_ENTRIES:
        if key in data:
            metrics[key.replace(" ", "_")] = data[key]
    for label in _SCOREBOARD_LABELS:
        metrics["State_" + label] = data.get("State_" + label, 0)

    state = "OK"
    msg_parts = []

    for key, label in _CHECK_LEVEL_ENTRIES:
        if key not in data:
            continue
        value = data[key]
        is_lower = key in _LOWER_LEVEL_KEYS
        state = _apply_levels(state, value, params.get(key), is_lower)
        if key in _SUMMARY_KEYS:
            msg_parts.append("%s: %s" % (label, _format_value(key, value)))

    scoreboard_parts = []
    for sb_label in _SCOREBOARD_LABELS:
        count = data.get("State_" + sb_label, 0)
        if count > 0:
            scoreboard_parts.append("%s: %d" % (sb_label, int(count)))
    details = ("Scoreboard: " + ", ".join(scoreboard_parts)) if scoreboard_parts else ""

    msg = ", ".join(msg_parts) if msg_parts else "Apache status OK"
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": details},
    }