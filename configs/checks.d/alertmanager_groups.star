DEFAULT_STATE_MAP = {
    "inactive": "OK",
    "pending": "OK",
    "firing": "CRIT",
    "none": "UNKNOWN",
    "not_applicable": "UNKNOWN",
}

STATE_NUM = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
NUM_STATE = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

DEFAULT_REMAPPING = [
    {
        "rule_names": ["Watchdog"],
        "map": {"inactive": 2, "pending": 2, "firing": 0, "none": 2, "not_applicable": 2},
    },
]

def _rule_state(rule_name, rule_state, alert_remapping):
    for remapping in alert_remapping:
        if rule_name in remapping.get("rule_names", []):
            m = remapping.get("map", {})
            v = m.get(rule_state)
            if v != None:
                return NUM_STATE.get(v, "UNKNOWN")
    return DEFAULT_STATE_MAP.get(rule_state, "UNKNOWN")

def _fetch_section(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 9090)
    scheme = params.get("scheme", "http")
    url = "%s://%s:%s/api/v1/rules" % (scheme, str(host), str(port))
    res = ctx.run(["curl", "-s", "--max-time", "10", url], mutates=False)
    if res.rc != 0:
        return None
    if not res.stdout:
        return None
    if not res.stdout.startswith("{"):
        return None
    data = json.decode(res.stdout)
    if data.get("status") != "success":
        return None
    section = {}
    for group in data.get("data", {}).get("groups", []):
        group_name = group.get("name", "")
        for rule in group.get("rules", []):
            if rule.get("type") != "alerting":
                continue
            rule_name = rule.get("name", "")
            rule_state = rule.get("state", "")
            if not rule_state:
                rule_state = "not_applicable"
            labels = rule.get("labels", {})
            severity = labels.get("severity", "not_applicable")
            annotations = rule.get("annotations", {})
            message = annotations.get("message", annotations.get("description"))
            if group_name not in section:
                section[group_name] = {}
            if rule_name not in section[group_name]:
                section[group_name][rule_name] = {
                    "name": rule_name,
                    "group": group_name,
                    "state": rule_state,
                    "severity": severity,
                    "message": message,
                }
    return section

def main(ctx, params):
    alert_remapping = params.get("alert_remapping", DEFAULT_REMAPPING)
    min_amount_rules = params.get("min_amount_rules", 3)
    no_group_services = params.get("no_group_services", [])

    if params.get("_discover"):
        section = _fetch_section(ctx, params)
        if section == None:
            return {
                "changed": False,
                "msg": "could not fetch prometheus rules",
                "data": {"discovery": []},
            }
        discovered = []
        for group_name in sorted(section.keys()):
            rules = section[group_name]
            if group_name in no_group_services:
                continue
            if len(rules) < min_amount_rules:
                continue
            discovered.append({
                "item": group_name,
                "params": {"min_amount_rules": min_amount_rules},
                "metrics": ["rule_count", "active_alerts"],
            })
        return {
            "changed": False,
            "msg": "discovered %d groups" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "")
    section = _fetch_section(ctx, params)
    if section == None:
        return {
            "changed": False,
            "msg": "could not fetch prometheus rules",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    group = section.get(item)
    if group == None:
        return {
            "changed": False,
            "msg": "group not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rule_count = len(group)
    worst_num = 0
    active_alerts = 0
    detail_lines = []

    for rule_name in sorted(group.keys()):
        rule = group[rule_name]
        state = _rule_state(rule.get("name", rule_name), rule.get("state", "none"), alert_remapping)
        num = STATE_NUM.get(state, 0)
        if state != "OK":
            active_alerts += 1
            if num > worst_num:
                worst_num = num
            msg = rule.get("message")
            detail_lines.append("%s: %s" % (rule_name, msg if msg != None else "No message"))

    overall = NUM_STATE.get(worst_num, "OK")
    summary = "Number of rules: %d" % rule_count
    if active_alerts > 0:
        summary = summary + ", active alerts: %d" % active_alerts

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": overall,
            "metrics": {"rule_count": rule_count, "active_alerts": active_alerts},
            "details": "\n".join(detail_lines),
        },
    }