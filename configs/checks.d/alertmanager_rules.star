DEFAULT_STATE_MAP = {
    "inactive": "OK",
    "pending": "OK",
    "firing": "CRIT",
    "none": "UNKNOWN",
    "not_applicable": "UNKNOWN",
}

INT_TO_STATE = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

DEFAULT_REMAPPING = [
    {
        "rule_names": ["Watchdog"],
        "map": {"inactive": 2, "pending": 2, "firing": 0, "none": 2, "not_applicable": 2},
    }
]

def _fetch_section(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 9090)
    url = "http://%s:%s/api/v1/rules" % (host, str(port))
    res = ctx.run(["curl", "-sf", "--max-time", "10", url], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    data = json.decode(res.stdout)
    if data.get("status") != "success":
        return None
    section = {}
    for g in data.get("data", {}).get("groups", []):
        group_name = g.get("name", "")
        for rule in g.get("rules", []):
            if rule.get("type") != "alerting":
                continue
            rule_name = rule.get("name", "")
            state_raw = rule.get("state", "")
            state_val = state_raw if state_raw else "not_applicable"
            labels = rule.get("labels", {})
            severity = labels.get("severity", "none")
            annotations = rule.get("annotations", {})
            message = annotations.get("message", annotations.get("description", ""))
            if group_name not in section:
                section[group_name] = {}
            if rule_name not in section[group_name]:
                section[group_name][rule_name] = {
                    "rule_name": rule_name,
                    "group_name": group_name,
                    "status": state_val,
                    "severity": severity,
                    "message": message,
                }
    return section

def _rule_state(rule, alert_remapping):
    rule_name = rule["rule_name"]
    status = rule["status"]
    for mapping in alert_remapping:
        if rule_name in mapping.get("rule_names", []):
            m = mapping.get("map", {})
            num = m.get(status, 3)
            return INT_TO_STATE.get(num, "UNKNOWN")
    return DEFAULT_STATE_MAP.get(status, "UNKNOWN")

def main(ctx, params):
    if params.get("_discover"):
        section = _fetch_section(ctx, params)
        if section == None:
            return {"changed": False, "msg": "could not fetch alertmanager rules",
                    "data": {"discovery": []}}
        min_rules = params.get("min_amount_rules", 3)
        no_group = params.get("no_group_services", [])
        out = []
        for group_name, rules in section.items():
            is_group = (group_name not in no_group) and (len(rules) >= min_rules)
            if is_group:
                continue
            for rule_name in rules:
                out.append({
                    "item": rule_name,
                    "params": {"alert_remapping": DEFAULT_REMAPPING},
                    "metrics": [],
                })
        return {"changed": False, "msg": "discovered %d rules" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    alert_remapping = params.get("alert_remapping", DEFAULT_REMAPPING)

    section = _fetch_section(ctx, params)
    if section == None:
        return {"changed": False, "msg": "could not fetch alertmanager data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rule = None
    for group in section.values():
        if item in group:
            rule = group[item]
            break

    if rule == None:
        return {"changed": False, "msg": "rule not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = _rule_state(rule, alert_remapping)
    severity = rule["severity"]
    group_name = rule["group_name"]
    message = rule["message"]

    parts = []
    if severity != "not_applicable":
        parts.append("Severity: " + severity)
    parts.append("Group name: " + group_name)
    if state != "OK":
        parts.append("Active alert")

    details = ""
    if state != "OK":
        details = message if message else "No message"

    return {"changed": False,
            "msg": ", ".join(parts),
            "data": {"state": state, "metrics": {}, "details": details}}