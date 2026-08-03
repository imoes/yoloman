# ===== Starlark translation of checkmk.mknotifyd_connection_v2 =====
# Monitors OMD (Open Monitoring Distribution) notification spooler connections.

_V2_SERVICE_NAMING = "Notification Spooler connection to"
_CONN_STATES = {
    "established": (0, "Alive"),
    "cooldown": (2, "Connection failed or terminated"),
    "initial": (1, "Initialized"),
    "connecting": (2, "Trying to connect"),
}
_SPOOL_KEYS = ["Count", "Oldest", "Youngest"]
_CONN_KEYS = [
    "Type", "State", "Status Message", "Since",
    "Connect Time", "Notifications Sent", "Notifications Received",
]

def _get_varname_value(line):
    if ":" not in line:
        return ("", "")
    parts = line.split(":", 1)
    return (parts[0], parts[1].strip())

def _parse_int(value):
    stripped = value.strip()
    if stripped == "":
        return 0
    first_token = stripped.split()[0]
    return int(first_token) if first_token.isdigit() else 0

def _parse_float(value):
    stripped = value.strip()
    if stripped == "":
        return 0.0
    first_token = stripped.split()[0]
    return float(first_token) if _is_numeric(first_token) else 0.0

def _parse_optional_int(value):
    stripped = value.strip()
    if stripped == "":
        return None
    first_token = stripped.split()[0]
    return int(first_token) if first_token.isdigit() else None

def _parse_optional_float(value):
    stripped = value.strip()
    if stripped == "":
        return None
    first_token = stripped.split()[0]
    return float(first_token) if _is_numeric(first_token) else None

def _is_numeric(s):
    if s == None or s == "":
        return False
    neg = s[0] == "-"
    body = s[1:] if neg else s
    if body == "":
        return False
    if "." in body:
        parts = body.split(".", 1)
        if len(parts) != 2:
            return False
        return _is_digit_str(parts[0]) and _is_digit_str(parts[1]) and (parts[0] != "" or parts[1] != "")
    return _is_digit_str(body)

def _is_digit_str(s):
    if s == None or s == "":
        return False
    for ch in s:
        if ch not in "0123456789":
            return False
    return True

def _parse_mknotifyd(raw_text):
    lines = raw_text.splitlines()
    
    sites = {}
    timestamp = 0.0
    
    if len(lines) > 0:
        first_line = lines[0].strip()
        if first_line.isdigit():
            timestamp = float(int(first_line))
    
    data = lines[1:]
    
    index = 0
    current_site_name = None
    while index < len(data):
        line = data[index]
        
        if line.startswith("[") and line.endswith("]"):
            site_name = line[1:-1]
            current_site_name = site_name
            spools = {}
            connections = {}
            connections_v2 = {}
            version = None
            updated = None
            
            if index + 1 < len(data):
                _, v = _get_varname_value(data[index + 1])
                if v != "":
                    version = v
            if index + 2 < len(data):
                _, val = _get_varname_value(data[index + 2])
                updated = _parse_optional_int(val)
            
            index = index + 2
            
            sites[site_name] = {
                "spools": spools,
                "connections": connections,
                "connections_v2": connections_v2,
                "version": version,
                "updated": updated,
                "current_site_name": current_site_name,
            }
        elif ":" in line:
            varname, value = _get_varname_value(line)
            
            if varname == "Site":
                pass
            elif varname == "Spool":
                index, spool = _get_spool(data, index)
                site_obj = sites.get(current_site_name) if current_site_name != None else None
                if site_obj != None:
                    site_obj["spools"][value] = spool
            elif varname == "Connection":
                index, connection = _get_connection(data, index)
                site_obj = sites.get(current_site_name) if current_site_name != None else None
                if site_obj != None:
                    site_obj["connections_v2"][value] = connection
        
        index = index + 1
    
    return {"sites": sites, "timestamp": timestamp}

def _get_spool(data, index):
    spool_data = {}
    for key in _SPOOL_KEYS:
        index = index + 1
        if index >= len(data):
            break
        _, value = _get_varname_value(data[index])
        spool_data[key.lower()] = value
    
    count = _parse_int(spool_data.get("count", "0"))
    oldest = _parse_optional_int(spool_data.get("oldest", ""))
    youngest = _parse_optional_int(spool_data.get("youngest", ""))
    
    return index, {"count": count, "oldest": oldest, "youngest": youngest}

def _get_connection(data, index):
    connection_data = {}
    for key in _CONN_KEYS:
        index = index + 1
        if index >= len(data):
            break
        varname, value = _get_varname_value(data[index])
        if varname != key:
            index = index - 1
            continue
        conn_key = key.lower().replace(" ", "_")
        connection_data[conn_key] = value
    
    type_ = connection_data.get("type", "")
    state = connection_data.get("state", "")
    status_message = connection_data.get("status_message")
    since = _parse_int(connection_data.get("since", "0"))
    connect_time_str = connection_data.get("connect_time")
    connect_time = _parse_optional_float(connect_time_str) if connect_time_str != None else None
    notifications_sent = _parse_int(connection_data.get("notifications_sent", "0"))
    notifications_received = _parse_int(connection_data.get("notifications_received", "0"))
    
    return index, {
        "type_": type_,
        "state": state,
        "status_message": status_message,
        "since": since,
        "connect_time": connect_time,
        "notifications_sent": notifications_sent,
        "notifications_received": notifications_received,
    }

def _get_connection_state(state_str, states_map):
    if state_str in states_map:
        state_code, summary = states_map[state_str]
        return state_code, summary
    return 3, "Unknown state: " + str(state_str)

def _state_code_to_name(code):
    if code == 0:
        return "OK"
    if code == 1:
        return "WARN"
    if code == 2:
        return "CRIT"
    return "UNKNOWN"

def main(ctx, params):
    if params.get("_discover"):
        omd_res = ctx.run(["omd", "--version"], mutates=False)
        if omd_res.rc == 127:
            return {"changed": False, "msg": "OMD not installed", "data": {"discovery": []}}
        if omd_res.rc != 0:
            return {"changed": False, "msg": "OMD not available", "data": {"discovery": []}}

        sites_res = ctx.run(["omd", "sites"], mutates=False)
        if sites_res.rc != 0:
            return {"changed": False, "msg": "no OMD sites found", "data": {"discovery": []}}

        sites = []
        for line in sites_res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 1:
                sites.append(parts[0])

        discovery = []
        for site in sites:
            notifyd_res = ctx.run(["omd", "notifyd", "status", site], mutates=False)
            if notifyd_res.rc == 127:
                continue
            if notifyd_res.rc != 0:
                continue

            section = _parse_mknotifyd(notifyd_res.stdout)
            site_obj = section["sites"].get(site)
            if site_obj == None:
                continue

            for conn_name in site_obj["connections_v2"].keys():
                item_name = site + " Notification Spooler connection to " + conn_name
                discovery.append({
                    "item": item_name,
                    "params": {},
                    "metrics": ["notifications_sent", "notifications_received"],
                })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if item == None or item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    naming = " Notification Spooler connection to "
    split_idx = item.find(naming)
    if split_idx < 0:
        return {
            "changed": False,
            "msg": "cannot parse item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    site_name = item[:split_idx]
    connection_name = item[split_idx + len(naming):]

    notifyd_res = ctx.run(["omd", "notifyd", "status", site_name], mutates=False)
    if notifyd_res.rc == 127:
        return {
            "changed": False,
            "msg": "OMD notifyd not available for site " + site_name,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if notifyd_res.rc != 0:
        return {
            "changed": False,
            "msg": "cannot read notifyd status for site " + site_name,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _parse_mknotifyd(notifyd_res.stdout)
    site_obj = section["sites"].get(site_name)
    if site_obj == None:
        return {
            "changed": False,
            "msg": "no such site: " + site_name,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    connection = site_obj["connections_v2"].get(connection_name)
    if connection == None:
        return {
            "changed": False,
            "msg": "no such connection: " + connection_name,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    conn_state, summary = _get_connection_state(connection["state"], _CONN_STATES)

    metrics = {}
    if connection["notifications_sent"] > 0:
        metrics["notifications_sent"] = float(connection["notifications_sent"])
    if connection["notifications_received"] > 0:
        metrics["notifications_received"] = float(connection["notifications_received"])

    if connection["state"] == "established":
        age = section["timestamp"] - connection["since"]
        metrics["uptime"] = age

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": _state_code_to_name(conn_state),
            "metrics": metrics,
            "details": "",
        },
    }