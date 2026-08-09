DEFAULT_LEVELS = {
    "1": 0,
    "2": 1,
    "3": 1,
    "4": 0,
    "5": 2,
    "6": 2,
    "7": 1,
    "8": 0,
}

STATUSES = {
    1: "NORMAL",
    2: "STARTUP",
    3: "SHUTDOWN",
    4: "ENABLE",
    5: "DISABLE",
    6: "INVALID",
    7: "NODEDUP",
    8: "UPGRADE",
}

MODE_SUMMARY = {
    1: ("UNKNOWN", "Mode: NONE"),
    2: ("OK", "Mode: STARTED"),
    3: ("CRIT", "Mode: STOPPED"),
}

LEVEL_STATE = {
    0: "OK",
    1: "WARN",
    2: "CRIT",
    3: "UNKNOWN",
}


def _parse_3par(stdout):
    if not stdout:
        return {}
    return json.decode(stdout)


def main(ctx, params):
    if params.get("_discover"):
        levels = params.get("levels", DEFAULT_LEVELS)
        res = ctx.run(["3par_remotecopy_show", "--format", "json"], mutates=False)
        section = _parse_3par(res.stdout)
        if res.rc == 127 or not section:
            return {"changed": False, "msg": "hpe_3par not installed",
                    "data": {"discovery": []}}
        mode = section.get("mode", 1)
        if mode > 1:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [
                        {"item": "", "params": {"levels": levels},
                         "metrics": []}]}}
        return {"changed": False, "msg": "no remote copy service",
                "data": {"discovery": []}}

    item = params.get("item", "")
    levels = params.get("levels", DEFAULT_LEVELS)
    res = ctx.run(["3par_remotecopy_show", "--format", "json"], mutates=False)
    if res.rc == 127 or not res.stdout:
        return {"changed": False, "msg": "hpe_3par not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_3par(res.stdout)
    if not section:
        return {"changed": False, "msg": "no remote copy data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mode = section.get("mode", 1)
    status = str(section.get("status", 6))
    status_readable = STATUSES.get(int(status), "UNKNOWN")

    m_state, m_msg = MODE_SUMMARY.get(mode, ("UNKNOWN", "Mode: NONE"))

    level = levels.get(status, 2)
    s_state = LEVEL_STATE.get(level, "UNKNOWN")

    if m_state == "OK" and s_state == "OK":
        state = "OK"
    elif m_state == "CRIT" or s_state == "CRIT":
        state = "CRIT"
    elif m_state == "WARN" or s_state == "WARN":
        state = "WARN"
    elif m_state == "UNKNOWN" or s_state == "UNKNOWN":
        state = "UNKNOWN"
    else:
        state = "OK"

    msg = "%s, Status: %s" % (m_msg, status_readable)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}