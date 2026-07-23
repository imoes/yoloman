# Status string from CSV -> params key
STATUS_TO_KEY = {
    "UP": "UP",
    "DOWN": "DOWN",
    "NOLB": "NOLB",
    "MAINT": "MAINT",
    "MAINT (via)": "MAINT_VIA",
    "MAINT (resolution)": "MAINT_RES",
    "DRAIN": "DRAIN",
    "no check": "NO_CHECK",
}

# Default check states: 0=OK 1=WARN 2=CRIT 3=UNKNOWN
DEFAULT_STATES = {
    "UP": 0,
    "DOWN": 2,
    "NOLB": 2,
    "MAINT": 2,
    "MAINT_VIA": 1,
    "MAINT_RES": 1,
    "DRAIN": 2,
    "NO_CHECK": 2,
}

STATE_NAMES = ["OK", "WARN", "CRIT", "UNKNOWN"]

def _is_digits(s):
    if len(s) == 0:
        return False
    for i in range(len(s)):
        c = s[i]
        if not (("0" <= c) and (c <= "9")):
            return False
    return True

def _parse_int(s):
    if s == None or s == "":
        return None
    neg = s.startswith("-")
    digits = s[1:] if neg else s
    if not _is_digits(digits):
        return None
    return int(s)

def _format_timespan(seconds):
    if seconds < 60:
        return "%d s" % seconds
    if seconds < 3600:
        return "%d m %d s" % (seconds // 60, seconds % 60)
    if seconds < 86400:
        return "%d h %d m" % (seconds // 3600, (seconds % 3600) // 60)
    return "%d d %d h" % (seconds // 86400, (seconds % 86400) // 3600)

def _get_stats(ctx, params):
    socket = params.get("socket", "/var/run/haproxy/admin.sock")
    cmd = "echo 'show stat' | socat STDIO unix-connect:" + socket
    return ctx.run(["bash", "-c", cmd], mutates=False)

def _parse_backends(output):
    backends = {}
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("#") or len(line) == 0:
            continue
        fields = line.split(",")
        if len(fields) <= 32:
            continue
        if fields[32] != "1":
            continue
        stot = _parse_int(fields[7])
        if stot == None:
            continue
        name = fields[0]
        status = fields[17]
        uptime = _parse_int(fields[23]) if len(fields) > 23 else None
        active = _parse_int(fields[19]) if len(fields) > 19 else None
        backup = _parse_int(fields[20]) if len(fields) > 20 else None
        backends[name] = {
            "status": status,
            "stot": stot,
            "uptime": uptime,
            "active": active,
            "backup": backup,
        }
    return backends

def main(ctx, params):
    if params.get("_discover"):
        res = _get_stats(ctx, params)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "haproxy stats unavailable",
                "data": {"discovery": []},
            }
        backends = _parse_backends(res.stdout)
        items = [
            {
                "item": name,
                "params": {},
                "metrics": ["active_backends", "stot"],
            }
            for name in sorted(backends.keys())
        ]
        return {
            "changed": False,
            "msg": "discovered %d backends" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    res = _get_stats(ctx, params)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "haproxy stats unavailable: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    backends = _parse_backends(res.stdout)
    data = backends.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "backend not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = data["status"]
    param_key = STATUS_TO_KEY.get(status)
    if param_key == None:
        state_num = 3
    else:
        state_num = params.get(param_key, DEFAULT_STATES.get(param_key, 2))
    state_str = STATE_NAMES[state_num] if ((0 <= state_num) and (state_num <= 3)) else "UNKNOWN"

    parts = ["Status: " + status]
    metrics = {}

    active = data["active"]
    backup = data["backup"]
    if active != None and active > 0:
        parts.append("Active: %d" % active)
        metrics["active_backends"] = active
    elif backup != None and backup > 0:
        parts.append("Backup")
    else:
        parts.append("Neither active nor backup")

    uptime = data["uptime"]
    if uptime != None:
        parts.append("%s since %s" % (status, _format_timespan(uptime)))

    stot = data["stot"]
    if stot != None:
        metrics["stot"] = stot

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {
            "state": state_str,
            "metrics": metrics,
            "details": "",
        },
    }