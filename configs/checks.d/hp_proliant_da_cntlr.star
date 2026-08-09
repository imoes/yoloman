PARSER_COND_MAP = {
    "1": "other",
    "2": "ok",
    "3": "degraded",
    "4": "failed",
}

PARSER_STATE_MAP = {
    "1": "other",
    "2": "ok",
    "3": "general failure",
    "4": "cable problem",
    "5": "powered off",
    "6": "cache module missing",
    "7": "degraded",
    "8": "enabled",
    "9": "disabled",
    "10": "standby (offline)",
    "11": "standby (spare)",
    "12": "in test",
    "13": "starting",
    "14": "absent",
    "16": "unavailable (offline)",
    "17": "deferring",
    "18": "quisced",
    "19": "updating",
    "20": "qualified",
}

PARSER_ROLE_MAP = {
    "1": "other",
    "2": "notDuplexed",
    "3": "active",
    "4": "backup",
}

STATE_OK = [
    "ok", "enabled", "disabled", "standby (spare)", "starting",
    "deferring", "quisced", "qualified",
]

STATE_WARN = [
    "other", "cache module missing", "standby (offline)",
    "in test", "updating",
]

STATE_CRIT = [
    "general failure", "cable problem", "powered off", "degraded",
    "absent", "unavailable (offline)",
]

COND_WARN = ["other", "degraded"]


def _cond_to_state(c):
    if c == "ok":
        return "OK"
    if c == "failed":
        return "CRIT"
    if c in COND_WARN:
        return "WARN"
    return "UNKNOWN"


def _state_to_state(s):
    if s in STATE_OK:
        return "OK"
    if s in STATE_CRIT:
        return "CRIT"
    if s in STATE_WARN:
        return "WARN"
    return "UNKNOWN"


def _worst(states):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    for st in states:
        if rank.get(st, 3) > rank.get(worst, 0):
            worst = st
    return worst


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.232.3.2.2.1.1"

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base],
            mutates=False,
        )
        if res.rc == 127 or res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk not available or device not responding",
                "data": {"discovery": []},
            }
        rows = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            val = parts[1]
            suffix = oid_full[len(base) + 1:]
            seg = suffix.split(".")
            if len(seg) < 2:
                continue
            index = seg[0]
            col = seg[1]
            if index not in rows:
                rows[index] = {}
            rows[index][col] = val

        if not rows:
            return {
                "changed": False,
                "msg": "discovered 0 controllers",
                "data": {"discovery": []},
            }

        discovery = []
        for index in rows:
            r = rows[index]
            cond = r.get("6")
            role = r.get("9")
            b_status = r.get("10")
            b_cond = r.get("12")
            if cond == "0" or role == "0" or b_status == "0" or b_cond == "0":
                continue
            discovery.append({
                "item": index,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d controllers" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + "." + item],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Controller " + item + " not found in SNMP data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    row = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        val = parts[1]
        suffix = oid_full[len(base) + 1:]
        seg = suffix.split(".")
        if len(seg) < 2:
            continue
        col = seg[1]
        row[col] = val

    cond = row.get("6", "")
    role = row.get("9", "")
    b_status = row.get("10", "")
    b_cond = row.get("12", "")

    if cond == "0" or role == "0" or b_status == "0" or b_cond == "0":
        return {
            "changed": False,
            "msg": "Controller " + item + " not found in SNMP data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    cond_state = _cond_to_state(PARSER_COND_MAP.get(cond, "other"))
    b_cond_state = _cond_to_state(PARSER_COND_MAP.get(b_cond, "other"))
    b_status_state = _state_to_state(PARSER_STATE_MAP.get(b_status, "other"))

    states_map = {
        "Condition": cond_state,
        "Board-Condition": b_cond_state,
        "Board-Status": b_status_state,
    }

    has_other = (
        PARSER_COND_MAP.get(cond) == "other" or
        PARSER_COND_MAP.get(b_cond) == "other" or
        PARSER_STATE_MAP.get(b_status) == "other"
    )
    role_desc = PARSER_ROLE_MAP.get(role, "unknown")
    if has_other:
        details_text = "The instrument agent does not recognize the status of the controller. You may need to upgrade the instrument agent."
    else:
        details_text = "Condition: " + cond_state + "; Board-Condition: " + b_cond_state + "; Board-Status: " + b_status_state + "; Role: " + role_desc

    summary = "Condition: " + cond_state + ", Board-Condition: " + b_cond_state + ", Board-Status: " + b_status_state + ", Role: " + role_desc

    worst = _worst(list(states_map.values()))
    if worst == "CRIT":
        state_label = "CRIT"
    elif worst == "WARN":
        state_label = "WARN"
    elif worst == "UNKNOWN":
        state_label = "UNKNOWN"
    else:
        state_label = "OK"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_label,
            "metrics": {},
            "details": details_text,
        },
    }