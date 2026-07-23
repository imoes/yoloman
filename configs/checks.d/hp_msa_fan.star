STATUS_NUMERIC_MAP = {
    "0": ("OK", "up"),
    "1": ("CRIT", "error"),
    "2": ("WARN", "off"),
    "3": ("UNKNOWN", "missing"),
}

HEALTH_NUMERIC_MAP = {
    "0": ("OK", "OK"),
    "1": ("WARN", "degraded"),
    "2": ("CRIT", "fault"),
    "3": ("CRIT", "N/A"),
    "4": ("UNKNOWN", "unknown"),
}

STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _xml_prop(block, name):
    needle = 'name="' + name + '"'
    idx = block.find(needle)
    if idx < 0:
        return ""
    after = block[idx + len(needle):]
    gt = after.find(">")
    if gt < 0:
        return ""
    lt = after.find("<", gt + 1)
    if lt < 0:
        return ""
    return after[gt + 1:lt].strip()

def _msa_login(ctx, host, user, password):
    url = "https://" + host + "/api/login?user=" + user + "&password=" + password
    res = ctx.run(["curl", "-sk", "--max-time", "10", url], mutates=False)
    if res.rc != 0 or not res.stdout:
        return ""
    marker = "Session key = "
    idx = res.stdout.find(marker)
    if idx < 0:
        return ""
    rest = res.stdout[idx + len(marker):]
    end = rest.find("<")
    if end < 0:
        return rest.strip()
    return rest[:end].strip()

def _msa_call(ctx, host, session_key, endpoint):
    url = "https://" + host + "/api/" + endpoint
    res = ctx.run(
        ["curl", "-sk", "--max-time", "10", "-H", "Cookie: sessionKey=" + session_key, url],
        mutates=False,
    )
    return res

def _parse_fans(xml):
    fans = []
    parts = xml.split('<OBJECT basetype="fan"')
    for part in parts[1:]:
        end = part.find("</OBJECT>")
        block = part[:end] if end >= 0 else part
        fan_id = _xml_prop(block, "durable-id")
        if not fan_id:
            continue
        fans.append({
            "item": fan_id,
            "name": _xml_prop(block, "name"),
            "status-numeric": _xml_prop(block, "status-numeric"),
            "speed": _xml_prop(block, "speed"),
            "health-numeric": _xml_prop(block, "health-numeric"),
            "health-reason": _xml_prop(block, "health-reason"),
        })
    return fans

def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("username", "manage")
    password = params.get("password", "")

    session_key = _msa_login(ctx, host, user, password)
    if not session_key:
        if params.get("_discover"):
            return {"changed": False, "msg": "login failed at " + host,
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "login failed at " + host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "login failed"}}

    res = _msa_call(ctx, host, session_key, "show/fans")
    _msa_call(ctx, host, session_key, "logout")

    if res.rc != 0 or not res.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "no fan data from " + host,
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no fan data from " + host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fans = _parse_fans(res.stdout)

    if params.get("_discover"):
        out = [{"item": f["item"], "params": {}, "metrics": ["fan_speed"]} for f in fans]
        return {"changed": False, "msg": "discovered %d fans" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    fan = None
    for f in fans:
        if f["item"] == item:
            fan = f
            break

    if fan == None:
        return {"changed": False, "msg": "fan not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "fan not found"}}

    speed_str = fan.get("speed", "0")
    fan_speed = int(speed_str) if speed_str.isdigit() else 0

    status_num = fan.get("status-numeric", "3")
    health_num = fan.get("health-numeric", "4")
    health_reason = fan.get("health-reason", "")

    s_entry = STATUS_NUMERIC_MAP.get(status_num, ("UNKNOWN", "unknown"))
    h_entry = HEALTH_NUMERIC_MAP.get(health_num, ("UNKNOWN", "unknown"))
    fan_state = s_entry[0]
    fan_state_readable = s_entry[1]
    health_state = h_entry[0]
    health_state_readable = h_entry[1]

    overall = fan_state
    if STATE_ORDER.get(health_state, 3) > STATE_ORDER.get(fan_state, 0):
        overall = health_state

    msg = "Status: %s, speed: %d RPM" % (fan_state_readable, fan_speed)
    details = ""
    if health_state != "OK" and health_reason:
        details = "health: %s (%s)" % (health_state_readable, health_reason)
        msg = msg + "; " + details

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall,
            "metrics": {"fan_speed": fan_speed},
            "details": details,
        },
    }