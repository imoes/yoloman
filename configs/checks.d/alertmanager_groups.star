def main(ctx, params):
    if params.get("_discover"):
        url = params.get("url", "http://localhost:9093")
        api_key = params.get("api_key", "")
        curl_cmd = ["curl", "-sf", "-H", "Accept: application/json"]
        if len(api_key) > 0:
            curl_cmd.append("-H")
            curl_cmd.append("X-API-Key: " + api_key)
        curl_cmd.append(url + "/api/v2/alerts")
        res = ctx.run(curl_cmd, mutates=False)
        if res.rc != 0 or len(res.stdout) == 0:
            return {"changed": False, "msg": "alertmanager not reachable", "data": {"discovery": []}}
        
        alerts = json.decode(res.stdout)
        if type(alerts) != "list":
            return {"changed": False, "msg": "invalid alertmanager response", "data": {"discovery": []}}
        
        # Group alerts by group label
        groups = {}
        for alert in alerts:
            if type(alert) != "dict":
                continue
            labels = alert.get("labels", [])
            if type(labels) != "dict":
                continue
            group_name = labels.get("group", "ungrouped")
            rule_name = labels.get("alertname", "")
            if len(rule_name) == 0:
                continue
            state = ""
            status = alert.get("status", [])
            if type(status) == "dict":
                state = status.get("state", "inactive")
            if len(state) == 0:
                state = "inactive"
            severity = labels.get("severity", "none")
            message = ""
            startsAt = alert.get("startsAt", "")
            if len(startsAt) > 0:
                message = "Alert since " + startsAt
            groups.setdefault(group_name, {})[rule_name] = {
                "name": rule_name,
                "group": group_name,
                "state": state,
                "severity": severity,
                "message": message,
            }
        
        # Apply discovery params
        group_services_config = {"min_amount_rules": 3, "no_group_services": []}
        summary_service = True
        
        discovery = []
        for group_name, rules in groups.items():
            create_group_service = group_name not in group_services_config["no_group_services"] and len(rules) >= group_services_config["min_amount_rules"]
            if create_group_service:
                discovery.append({"item": group_name, "params": {"alert_remapping": default_check_parameters["alert_remapping"]}, "metrics": ["rule_count"]})
        
        return {"changed": False, "msg": "discovered %d groups" % len(discovery), "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    url = params.get("url", "http://localhost:9093")
    api_key = params.get("api_key", "")
    curl_cmd = ["curl", "-sf", "-H", "Accept: application/json"]
    if len(api_key) > 0:
        curl_cmd.append("-H")
        curl_cmd.append("X-API-Key: " + api_key)
    curl_cmd.append(url + "/api/v2/alerts")
    res = ctx.run(curl_cmd, mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "alertmanager not reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if len(res.stdout) == 0:
        return {"changed": False, "msg": "no alerts returned", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    alerts = json.decode(res.stdout)
    if type(alerts) != "list":
        return {"changed": False, "msg": "invalid alertmanager response", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Build groups
    groups = {}
    for alert in alerts:
        if type(alert) != "dict":
            continue
        labels = alert.get("labels", [])
        if type(labels) != "dict":
            continue
        group_name = labels.get("group", "ungrouped")
        rule_name = labels.get("alertname", "")
        if len(rule_name) == 0:
            continue
        state = "inactive"
        status = alert.get("status", [])
        if type(status) == "dict":
            st = status.get("state", "inactive")
            if len(st) > 0:
                state = st
        severity = labels.get("severity", "none")
        message = ""
        startsAt = alert.get("startsAt", "")
        if len(startsAt) > 0:
            message = "Alert since " + startsAt
        groups.setdefault(group_name, {})[rule_name] = {
            "name": rule_name,
            "group": group_name,
            "state": state,
            "severity": severity,
            "message": message,
        }
    
    group = groups.get(item)
    if group == None:
        return {"changed": False, "msg": "group %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    details = "Number of rules: %s" % len(group)
    worst_state = 0
    for rule in group.values():
        state_val = _get_rule_state(rule, params)
        if state_val > worst_state:
            worst_state = state_val
        if state_val != 0:
            details = details + "\nActive alert: %s (%s)" % (rule["name"], rule["message"])
    
    if worst_state == 0:
        state = "OK"
    elif worst_state == 1:
        state = "WARN"
    elif worst_state == 2:
        state = "CRIT"
    elif worst_state == 3:
        state = "UNKNOWN"
    else:
        state = "UNKNOWN"
    
    return {"changed": False, "msg": details, "data": {"state": state, "metrics": {"rule_count": len(group)}, "details": details}}


default_check_parameters = {"alert_remapping": [{"rule_names": ["Watchdog"], "map": {"inactive": 2, "pending": 2, "firing": 0, "none": 2, "not_applicable": 2}}]}

default_state_mapping = {"inactive": 0, "pending": 0, "firing": 2, "none": 3, "not_applicable": 3}


def _get_rule_state(rule, params):
    mapping = _get_mapping(rule, params)
    if mapping != None:
        state_str = str(rule["state"])
        if state_str in mapping:
            return mapping[state_str]
        return 3
    if rule["state"] in default_state_mapping:
        return default_state_mapping[rule["state"]]
    return 3


def _get_mapping(rule, params):
    for mapping in params.get("alert_remapping", []):
        if rule["name"] in mapping.get("rule_names", []):
            return mapping.get("map", [])
    return None