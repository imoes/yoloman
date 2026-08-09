def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "admin")
    password = params.get("password", "")
    port = params.get("port", 443)

    base_url = "https://%s:%d/api/v1" % (host, port)

    # Probe: verify the StoreOnce REST API is actually reachable
    probe = ctx.run([
        "curl", "-sk", "-u", "%s:%s" % (username, password),
        "-w", "\n%{http_code}", base_url + "/servicesets",
    ], mutates=False)
    http_body = probe.stdout or ""
    lines = http_body.splitlines()
    http_code = ""
    if len(lines) > 0:
        http_code = lines[-1].strip()
        body = "\n".join(lines[:-1])
    else:
        body = ""

    # 127 or non-200 means the StoreOnce API is not present / not reachable
    if probe.rc == 127 or http_code != "200" or not body:
        if params.get("_discover"):
            return {"changed": False, "msg": "StoreOnce API not reachable", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "StoreOnce servicesets API not reachable on %s" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse the JSON response — the StoreOnce API returns a list of serviceset objects
    parsed = json_decode_safe(body)
    if parsed == None or type(parsed) != "list":
        if params.get("_discover"):
            return {"changed": False, "msg": "no servicesets parsed", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "StoreOnce servicesets API returned unexpected format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Build a dict keyed by ServiceSet ID, mimicking storeonce.parse_storeonce_servicesets
    section = {}
    for obj in parsed:
        if type(obj) == "dict":
            sid = str(obj.get("id", obj.get("ServiceSet ID", "")))
            if sid != "":
                section[sid] = obj

    if params.get("_discover"):
        discovery = []
        for sid in sorted(section.keys()):
            obj = section[sid]
            alias = obj.get("alias", obj.get("ServiceSet Alias", ""))
            name = obj.get("name", obj.get("ServiceSet Name", ""))
            display = alias if alias != "" else name
            if display == "":
                display = "ServiceSet %s" % sid
            discovery.append({
                "item": display,
                "params": {},
                "metrics": ["health_level", "replication_health_level", "housekeeping_health_level"],
            })
        return {
            "changed": False,
            "msg": "discovered %d servicesets" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE — single item
    item = params.get("item", "")
    values = None
    for sid in section:
        obj = section[sid]
        alias = obj.get("alias", obj.get("ServiceSet Alias", ""))
        name = obj.get("name", obj.get("ServiceSet Name", ""))
        if alias == item or name == item or ("ServiceSet %s" % sid) == item:
            values = obj
            break

    if values == None:
        return {
            "changed": False,
            "msg": "no such serviceset: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Build the display summary
    alias = values.get("alias", values.get("ServiceSet Alias", ""))
    name = values.get("name", values.get("ServiceSet Name", ""))
    summary_parts = []
    if alias != "":
        summary_parts.append("Alias: %s" % alias)
    elif name != "":
        summary_parts.append("Name: %s" % name)

    overall_status = safe_str(values.get("overallStatus", values.get("Overall Status", "Unknown")))
    overall_health = safe_str(values.get("overallHealth", values.get("Overall Health", "Unknown")))
    summary_parts.append("Overall Status: %s, Overall Health: %s" % (overall_status, overall_health))

    # Component health checks with level->state mapping (1=OK, 2=WARN, 3=CRIT, 4=UNKNOWN)
    state = "OK"
    component_metrics = {}
    component_states = {}
    for component_key, display_name in [
        ("serviceSetHealthLevel", "ServiceSet Health"),
        ("replicationHealthLevel", "Replication Health"),
        ("housekeepingHealthLevel", "Housekeeping Health"),
    ]:
        level = safe_level(values, component_key, component_key)
        health = safe_str(values.get(component_key.replace("Level", ""), values.get(display_name, "Unknown")))
        st = level_to_state(level)
        component_states[display_name] = st
        component_metrics[component_key] = level
        if state_rank(st) > state_rank(state):
            state = st

    metrics = {}
    for k, v in component_metrics.items():
        metrics[k] = v

    details = "; ".join(["%s: %s (%s)" % (k, v, component_states[k]) for k, v in component_states.items()])

    msg = ", ".join(summary_parts)
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": details},
    }


# --- helpers ---

def json_decode_safe(s):
    if s == "" or s == None:
        return None
    return json.decode(s)

def safe_str(v):
    if v == None:
        return ""
    return str(v)

def safe_level(values, *keys):
    for k in keys:
        if values.get(k) != None:
            v = values.get(k)
            if type(v) == "int":
                return v
            if type(v) == "string" and v.isdigit():
                return int(v)
    return 4  # default to UNKNOWN level

def level_to_state(level):
    # StoreOnce health levels: 1=OK, 2=WARN, 3=CRIT, 4=UNKNOWN (others)
    if level == 1:
        return "OK"
    if level == 2:
        return "WARN"
    if level == 3:
        return "CRIT"
    return "UNKNOWN"

def state_rank(s):
    ranks = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    return ranks.get(s, 3)