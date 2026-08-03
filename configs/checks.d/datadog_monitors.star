# Default Datadog-to-Checkmk state mapping (datadog_state -> checkmk_state)
_DEFAULT_STATE_MAPPING = {
    "Alert": 2,
    "Ignored": 3,
    "No Data": 0,
    "OK": 0,
    "Skipped": 3,
    "Unknown": 3,
    "Warn": 1,
}

# Default states to discover
_DEFAULT_STATES_DISCOVER = [
    "Alert",
    "Ignored",
    "No Data",
    "OK",
    "Skipped",
    "Unknown",
    "Warn",
]

# Checkmk state name lookup (numeric Checkmk state -> name)
_STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def _fetch_monitors(ctx, params):
    api_url = params.get("api_url", "https://api.datadoghq.com")
    api_key = params.get("api_key")
    if api_key == None:
        return None
    endpoint = api_url.rstrip("/") + "/api/v1/monitor"
    res = ctx.run([
        "curl", "-fsSL",
        "-H", "DD-API-KEY: " + api_key,
        endpoint,
    ], mutates=False)
    if res.rc != 0:
        return None
    if not res.stdout:
        return None
    monitors = json.decode(res.stdout)
    return monitors if type(monitors) == "list" else None


def _parse_monitors(ctx, params):
    monitors = _fetch_monitors(ctx, params)
    if monitors == None:
        return None
    result = {}
    for monitor_dict in monitors:
        name = monitor_dict.get("name", "")
        if name == "":
            continue
        options = monitor_dict.get("options", {})
        thresholds = options.get("thresholds", {})
        result[name] = {
            "state": monitor_dict.get("overall_state", "Unknown"),
            "message": monitor_dict.get("message", "No message"),
            "thresholds": thresholds,
            "tags": monitor_dict.get("tags", []),
        }
    return result


def main(ctx, params):
    if params.get("_discover"):
        monitors = _parse_monitors(ctx, params)
        if monitors == None:
            return {
                "changed": False,
                "msg": "Datadog monitors not available",
                "data": {"discovery": [], "host_labels": {}},
            }
        states_discover = params.get("states_discover", _DEFAULT_STATES_DISCOVER)
        if type(states_discover) != "list":
            states_discover = list(states_discover)
        discovery = []
        for name, monitor in monitors.items():
            if monitor["state"] in states_discover:
                discovery.append({
                    "item": name,
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d monitors" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    item = params.get("item", "")
    monitors = _parse_monitors(ctx, params)
    if monitors == None:
        return {
            "changed": False,
            "msg": "Datadog monitors not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    monitor = monitors.get(item)
    if monitor == None:
        return {
            "changed": False,
            "msg": "no such monitor: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    state_mapping = params.get("state_mapping", _DEFAULT_STATE_MAPPING)
    if state_mapping == None:
        state_mapping = _DEFAULT_STATE_MAPPING
    cm_state = state_mapping.get(monitor["state"], 3)
    state_name = _STATE_NAMES.get(cm_state, "UNKNOWN")

    details = monitor["message"] if monitor["message"] != "" else "No message"

    msg_parts = ["Overall state: " + monitor["state"]]

    thresholds = monitor["thresholds"]
    if type(thresholds) == "dict" and len(thresholds) > 0:
        threshold_strs = []
        for k in sorted(thresholds.keys()):
            threshold_strs.append(k + ": " + str(thresholds[k]))
        if len(threshold_strs) > 0:
            msg_parts.append("Datadog thresholds: " + ", ".join(threshold_strs))

    tags_to_show = params.get("tags_to_show", [])
    if tags_to_show == None:
        tags_to_show = []
    if type(tags_to_show) != "list":
        tags_to_show = list(tags_to_show)

    matching_tags = []
    tags = monitor["tags"]
    if type(tags) == "list":
        for tag in tags:
            matched = False
            for tag_regex in tags_to_show:
                if tag.find(tag_regex) != -1:
                    matched = True
                    break
            if matched:
                matching_tags.append(tag)
    if len(matching_tags) > 0:
        msg_parts.append("Datadog tags: " + ", ".join(matching_tags))

    return {
        "changed": False,
        "msg": " | ".join(msg_parts),
        "data": {
            "state": state_name,
            "metrics": {},
            "details": details,
        },
    }