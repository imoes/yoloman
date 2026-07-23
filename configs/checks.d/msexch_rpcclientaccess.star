def main(ctx, params):
    if params.get("_discover"):
        cmd = [
            "powershell", "-Command",
            "Get-WmiObject -Class MSExchangeRPCClientAccess -Property * | Select-Object -Property RPCAveragedLatency,RPCRequests,UserCount,ActiveUserCount | ConvertTo-Json -Compress"
        ]
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "no WMI data (class MSExchangeRPCClientAccess not found)",
                "data": {"discovery": []}
            }

        data = json.decode(res.stdout)
        if type(data) != "dict":
            return {
                "changed": False,
                "msg": "unexpected WMI data format",
                "data": {"discovery": []}
            }

        if data.get("RPCAveragedLatency") != None or data.get("RPCRequests") != None:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {
                                "latency_s": ["fixed", [0.2, 0.25]],
                                "requests": ["fixed", [30, 40]]
                            },
                            "metrics": [
                                "average_latency_s",
                                "requests_per_sec",
                                "current_users",
                                "active_users"
                            ]
                        }
                    ]
                },
            }
        else:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }

    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "unknown item: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    cmd = [
        "powershell", "-Command",
        "Get-WmiObject -Class MSExchangeRPCClientAccess -Property * | Select-Object -Property RPCAveragedLatency,RPCRequests,UserCount,ActiveUserCount | ConvertTo-Json -Compress"
    ]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "no WMI data (class MSExchangeRPCClientAccess not found)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    data = json.decode(res.stdout)
    if type(data) != "dict":
        return {
            "changed": False,
            "msg": "unexpected WMI data format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    latency_raw = data.get("RPCAveragedLatency")
    requests_raw = data.get("RPCRequests")
    users_raw = data.get("UserCount")
    active_users_raw = data.get("ActiveUserCount")

    latency_s = None
    if latency_raw != None:
        s = str(latency_raw)
        if s.lstrip('-').isdigit():
            latency_s = float(latency_raw) / 1000.0

    requests = None
    if requests_raw != None:
        s = str(requests_raw)
        if s.lstrip('-').isdigit():
            requests = int(requests_raw)

    users = None
    if users_raw != None:
        s = str(users_raw)
        if s.lstrip('-').isdigit():
            users = int(users_raw)

    active_users = None
    if active_users_raw != None:
        s = str(active_users_raw)
        if s.lstrip('-').isdigit():
            active_users = int(active_users_raw)

    latency_levels = params.get("latency_s", ["fixed", [0.2, 0.25]])
    requests_levels = params.get("requests", ["fixed", [30, 40]])

    state = "OK"
    msg_parts = []

    if latency_s != None:
        warn_lat = None
        crit_lat = None
        if type(latency_levels) == "list" and len(latency_levels) == 2:
            if latency_levels[0] == "fixed" and type(latency_levels[1]) == "list" and len(latency_levels[1]) == 2:
                warn_lat = latency_levels[1][0]
                crit_lat = latency_levels[1][1]

        if crit_lat != None and latency_s >= crit_lat:
            state = "CRIT"
        elif warn_lat != None and latency_s >= warn_lat:
            if state != "CRIT":
                state = "WARN"
        msg_parts.append("Average latency: %f s" % latency_s)

    if requests != None:
        warn_req = None
        crit_req = None
        if type(requests_levels) == "list" and len(requests_levels) == 2:
            if requests_levels[0] == "fixed" and type(requests_levels[1]) == "list" and len(requests_levels[1]) == 2:
                warn_req = requests_levels[1][0]
                crit_req = requests_levels[1][1]

        if crit_req != None and requests >= crit_req:
            state = "CRIT"
        elif warn_req != None and requests >= warn_req:
            if state != "CRIT":
                state = "WARN"
        msg_parts.append("RPC Requests/sec: %d" % requests)

    if users != None:
        msg_parts.append("Users: %d" % users)

    if active_users != None:
        msg_parts.append("Active users: %d" % active_users)

    metrics = {}
    if latency_s != None:
        metrics["average_latency_s"] = latency_s
    if requests != None:
        metrics["requests_per_sec"] = requests
    if users != None:
        metrics["current_users"] = users
    if active_users != None:
        metrics["active_users"] = active_users

    if len(msg_parts) == 0:
        return {
            "changed": False,
            "msg": "no metric data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }