# Module: 3par_remotecopy.star
# Read-only Starlark check for HPE 3PAR remote copy status
# No mutation; always changed=False

# Mappings (constants at top level per Starlark rules)
THREEPAR_REMOTECOPY_DEFAULT_LEVELS = {
    "1": 0,  # NORMAL
    "2": 1,  # STARTUP
    "3": 1,  # SHUTDOWN
    "4": 0,  # ENABLE
    "5": 2,  # DISABLE
    "6": 2,  # INVALID
    "7": 1,  # NODEDUP
    "8": 0,  # UPGRADE
}

MODES = {
    1: "Mode: NONE",
    2: "Mode: STARTED",
    3: "Mode: STOPPED",
}

MODE_STATE = {
    1: "UNKNOWN",
    2: "OK",
    3: "CRIT",
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

STATE_MAP = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/driver/3par/remotecopy"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        data = json.decode(res.stdout.strip()) if res.stdout.strip() else {}
        mode = data.get("mode", 1)
        if mode > 1:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": THREEPAR_REMOTECOPY_DEFAULT_LEVELS, "metrics": []}]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    res = ctx.run(["cat", "/proc/driver/3par/remotecopy"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "No data from remote copy",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    data = json.decode(res.stdout.strip())
    
    mode = int(data.get("mode", 1))
    status = str(data.get("status", 6))
    status_readable = STATUSES.get(int(status), "UNKNOWN")

    mode_state_str = MODE_STATE.get(mode, "UNKNOWN")
    mode_msg = MODES.get(mode, "Mode: UNKNOWN")

    levels = params.get("levels", THREEPAR_REMOTECOPY_DEFAULT_LEVELS)
    status_state_int = int(levels.get(status, 2))
    status_state_str = STATE_MAP.get(status_state_int, "CRIT")

    if mode_state_str == "CRIT" or status_state_str == "CRIT":
        state = "CRIT"
    elif mode_state_str == "WARN" or status_state_str == "WARN":
        state = "WARN"
    elif mode_state_str == "OK" and status_state_str == "OK":
        state = "OK"
    else:
        state = "UNKNOWN"

    msg = "%s, Status: %s" % (mode_msg, status_readable)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }