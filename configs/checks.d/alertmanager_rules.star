def main(ctx, params):
    api_url = params.get("api_url", "http://localhost:9093/api/v2/status")
    timeout = params.get("timeout", 10)

    probe = ctx.run(
        ["curl", "-fsS", "-m", str(timeout), api_url],
        mutates=False,
    )

    if probe.rc != 0 or not probe.stdout:
        return {
            "changed": False,
            "msg": "Alertmanager is not reachable at %s" % api_url,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    data = json.decode(probe.stdout)
    rules_data = data.get("data", data)
    groups = rules_data.get("groups", [])

    section = {}
    for group in groups:
        gname = group.get("name", "")
        group_rules = {}
        rules_list = group.get("rules", [])
        for rule in rules_list:
            rname = rule.get("name", "")
            rstate = rule.get("state", "not_applicable")
            rsev = rule.get("severity", "not_applicable")
            rmsg = rule.get("message", None)
            group_rules[rname] = {
                "rule_name": rname,
                "group_name": gname,
                "status": rstate,
                "severity": rsev,
                "message": rmsg,
            }
        section[gname] = group_rules

    default_state_mapping = {
        "inactive": 0,
        "pending": 0,
        "firing": 2,
        "none": 3,
        "not_applicable": 3,
    }

    default_alert_remapping = [
        {"rule_names": ["Watchdog"],
         "map": {"inactive": 2, "pending": 2, "firing": 0, "none": 2, "not_applicable": 2}},
    ]

    alert_remapping = params.get("alert_remapping", default_alert_remapping)

    def get_mapping(rname):
        for m in alert_remapping:
            rnames = m.get("rule_names", [])
            if rname in rnames:
                return m.get("map")
        return None

    def rule_state_value(rule):
        rname = rule["rule_name"]
        st = rule["status"]
        mp = get_mapping(rname)
        if mp:
            return mp.get(st, 3)
        return default_state_mapping.get(st, 3)

    def state_from_value(val):
        if val == 0:
            return "OK"
        elif val == 1:
            return "WARN"
        elif val == 2:
            return "CRIT"
        else:
            return "UNKNOWN"

    if params.get("_discover"):
        discovery = []
        if params.get("summary_service", True):
            discovery.append({
                "item": "",
                "params": {},
                "metrics": ["rule_count"],
            })

        min_amount = 3
        group_services = params.get("group_services")
        if group_services:
            min_amount = group_services.get("min_amount_rules", 3)
        no_group_services = params.get("no_group_services", [])

        for gname in sorted(section.keys()):
            rules = section[gname]
            if gname in no_group_services:
                continue
            if len(rules) >= min_amount:
                discovery.append({
                    "item": gname,
                    "params": {},
                    "metrics": ["rule_count"],
                })
                continue
            for rname in sorted(rules.keys()):
                discovery.append({
                    "item": rname,
                    "params": {},
                    "metrics": ["firing", "pending", "inactive"],
                })

        return {
            "changed": False,
            "msg": "discovered %d services" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    if item == "":
        total = 0
        worst = 0
        worst_msg = ""
        for gname in section:
            rules = section[gname]
            total = total + len(rules)
            for rname in rules:
                rule = rules[rname]
                val = rule_state_value(rule)
                if val > worst:
                    worst = val
                    worst_msg = "%s (%s)" % (rname, rule["status"])
        state_str = state_from_value(worst)
        msg = "Alertmanager Summary - %d rules" % total
        if worst_msg:
            msg = msg + ", worst: " + worst_msg
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state_str,
                "metrics": {"rule_count": total},
                "details": "",
            },
        }

    if item in section:
        rules = section[item]
        rule_count = len(rules)
        worst = 0
        for rname in rules:
            rule = rules[rname]
            val = rule_state_value(rule)
            if val > worst:
                worst = val
        state_str = state_from_value(worst)
        return {
            "changed": False,
            "msg": "Alert Rule Group %s - %d rules" % (item, rule_count),
            "data": {
                "state": state_str,
                "metrics": {"rule_count": rule_count},
                "details": "Number of rules: %d" % rule_count,
            },
        }

    found_rule = None
    found_group = None
    for gname in section:
        rules = section[gname]
        if item in rules:
            found_rule = rules[item]
            found_group = gname
            break

    if found_rule == None:
        return {
            "changed": False,
            "msg": "Alert Rule %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    val = rule_state_value(found_rule)
    state_str = state_from_value(val)

    sev = found_rule["severity"]
    msg_parts = []
    if sev != "none" and sev != "not_applicable":
        msg_parts.append("Severity: %s" % sev)
    msg_parts.append("Group name: %s" % found_rule["group_name"])
    if val != 0:
        msg_parts.append("Active alert")
        rmsg = found_rule["message"]
        if rmsg:
            msg_parts.append(rmsg)
        else:
            msg_parts.append("No message")

    metrics = {
        "firing": 1 if found_rule["status"] == "firing" else 0,
        "pending": 1 if found_rule["status"] == "pending" else 0,
        "inactive": 1 if found_rule["status"] == "inactive" else 0,
    }

    rmsg_val = found_rule["message"]
    details = rmsg_val if rmsg_val else ""

    return {
        "changed": False,
        "msg": "Alert Rule %s - %s" % (item, ", ".join(msg_parts)),
        "data": {
            "state": state_str,
            "metrics": metrics,
            "details": details,
        },
    }