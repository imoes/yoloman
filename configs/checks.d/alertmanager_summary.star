DEFAULT_STATE_MAP = {
    "inactive": "OK",
    "pending": "OK",
    "firing": "CRIT",
    "none": "UNKNOWN",
    "not_applicable": "UNKNOWN",
}

STATE_PRIORITY = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}

INT_TO_STATE = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

DEFAULT_ALERT_REMAPPING = [
    {
        "rule_names": ["Watchdog"],
        "map": {"inactive": 2, "pending": 2, "firing": 0, "none": 2, "not_applicable": 2},
    },
]


def _get_rule_state(rule_name, state, alert_remapping):
    for mapping in alert_remapping:
        if rule_name in mapping.get("rule_names", []):
            m = mapping.get("map", {})
            v = m.get(state)
            if v == None:
                v = m.get("not_applicable", 3)
            return INT_TO_STATE.get(v, "UNKNOWN")
    return DEFAULT_STATE_MAP.get(state, "UNKNOWN")


def _fetch_section(ctx, host, port):
    url = "http://%s:%s/api/v1/rules" % (host, str(port))
    res = ctx.run(["curl", "-sf", "--max-time", "10", url], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    data = json.decode(res.stdout)
    if data.get("status") != "success":
        return None
    groups = data.get("data", {}).get("groups", [])
    section = {}
    for g in groups:
        group_name = g.get("name", "")
        for rule in g.get("rules", []):
            if rule.get("type") != "alerting":
                continue
            rule_name = rule.get("name", "")
            raw_state = rule.get("state", "")
            state = raw_state if raw_state else "not_applicable"
            labels = rule.get("labels", {})
            severity = labels.get("severity", "none")
            annotations = rule.get("annotations", {})
            message = annotations.get("message", annotations.get("summary", ""))
            if group_name not in section:
                section[group_name] = {}
            if rule_name not in section[group_name]:
                section[group_name][rule_name] = {
                    "name": rule_name,
                    "group_name": group_name,
                    "state": state,
                    "severity": severity,
                    "message": message,
                }
    return section


def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 9090)
    alert_remapping = params.get("alert_remapping", DEFAULT_ALERT_REMAPPING)

    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {"alert_remapping": DEFAULT_ALERT_REMAPPING},
                    "metrics": ["total_rules", "active_alerts"],
                },
            ]},
        }

    section = _fetch_section(ctx, host, port)
    if section == None:
        return {
            "changed": False,
            "msg": "Cannot fetch rules from Prometheus at %s:%s" % (host, str(port)),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total = 0
    for grp in section.values():
        total = total + len(grp)

    worst = "OK"
    details_lines = []

    for grp in section.values():
        for rule in grp.values():
            rule_state = _get_rule_state(rule["name"], rule["state"], alert_remapping)
            if rule_state != "OK":
                if STATE_PRIORITY.get(rule_state, 0) > STATE_PRIORITY.get(worst, 0):
                    worst = rule_state
                rmsg = rule["message"] if rule["message"] else "No message"
                details_lines.append("%s: %s" % (rule["name"], rmsg))

    n_active = len(details_lines)
    summary_msg = "Number of rules: %d" % total
    if n_active > 0:
        summary_msg = summary_msg + ", Active alerts: %d" % n_active

    return {
        "changed": False,
        "msg": summary_msg,
        "data": {
            "state": worst,
            "metrics": {"total_rules": total, "active_alerts": n_active},
            "details": "\n".join(details_lines),
        },
    }