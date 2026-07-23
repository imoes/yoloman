def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        cmd = [
            "powershell", "-Command",
            "Get-WmiObject -Class \"LS:DATAPROXY - Server Connections\" -Namespace \"root\\cimv2\" | Select-Object InstanceName, \"DATAPROXY - Current count of server connections that are throttled\", \"DATAPROXY - System is throttling\" | ConvertTo-Json -Compress"
        ]
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to query WMI", "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "WMI response empty", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        items = []
        entries = data if type(data) == "list" else [data]
        for entry in entries:
            instance_name = entry.get("InstanceName", "")
            if instance_name == None:
                instance_name = ""
            items.append({
                "item": str(instance_name),
                "params": {"throttled_connections": {"upper": (1, 2)}},
                "metrics": ["dataproxy_connections_throttled"]
            })
        return {"changed": False, "msg": "discovered %d instances" % len(items), "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    throttled_levels = params.get("throttled_connections", {"upper": (1, 2)})

    filter_clause = ""
    if item != "" and item != "_Total":
        escaped = str(item).replace("'", "''")
        filter_clause = " WHERE InstanceName='" + escaped + "'"

    cmd = [
        "powershell", "-Command",
        "Get-WmiObject -Class \"LS:DATAPROXY - Server Connections\"" + filter_clause + " -Namespace \"root\\cimv2\" | Select-Object InstanceName, \"DATAPROXY - Current count of server connections that are throttled\", \"DATAPROXY - System is throttling\" | ConvertTo-Json -Compress"
    ]
    res = ctx.run(cmd, mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "failed to query WMI", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not res.stdout:
        return {"changed": False, "msg": "WMI response empty", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)
    entries = data if type(data) == "list" else [data]
    if len(entries) == 0:
        return {"changed": False, "msg": "instance not found: " + str(item), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    entry = entries[0]
    throttled_str = entry.get("DATAPROXY - Current count of server connections that are throttled")
    throttling_str = entry.get("DATAPROXY - System is throttling")

    throttled = 0
    if throttled_str != None and str(throttled_str).strip() != "":
        candidate = str(throttled_str).strip()
        if candidate.lstrip("-").isdigit():
            throttled = int(candidate)

    is_throttling = False
    if throttling_str != None:
        candidate = str(throttling_str).strip()
        if candidate.lstrip("-").isdigit():
            val = int(candidate)
            if val != 0:
                is_throttling = True

    warn = throttled_levels.get("upper", (1, 2))[0]
    crit = throttled_levels.get("upper", (1, 2))[1]

    state = "OK"
    if is_throttling:
        state = "CRIT"
    elif throttled >= crit:
        state = "CRIT"
    elif throttled >= warn:
        state = "WARN"

    msg = "Throttled connections: %d" % throttled
    if is_throttling:
        msg = msg + ", SYSTEM IS THROTTLING"

    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"dataproxy_connections_throttled": throttled}, "details": ""}}