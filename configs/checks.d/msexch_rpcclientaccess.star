def main(ctx, params):
    if params.get("_discover"):
        present = detect_exchange(ctx)
        if not present:
            return {"changed": False, "msg": "Exchange RPC Client Access not found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "",
                    "params": {
                        "latency_s": params.get("latency_s", (0.2, 0.25)),
                        "requests": params.get("requests", (30, 40)),
                    },
                    "metrics": ["average_latency_s", "requests_per_sec", "current_users", "active_users"]}]}}

    data = read_exchange_counters(ctx)
    if data == None:
        return {"changed": False, "msg": "No Exchange RPC Client Access data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "RPC Client Access performance counters not found"}}

    latency_raw = data.get("RPCAveragedLatency", "")
    latency_val = 0.0
    if latency_raw != "" and latency_raw != None:
        latency_val = float(latency_raw) / 1000.0

    latency_levels = params.get("latency_s", (0.2, 0.25))
    req_levels = params.get("requests", (30, 40))

    lat_warn = latency_levels[0] if len(latency_levels) >= 1 else 0.2
    lat_crit = latency_levels[1] if len(latency_levels) >= 2 else 0.25
    latency_state = "OK"
    if latency_val >= lat_crit:
        latency_state = "CRIT"
    elif latency_val >= lat_warn:
        latency_state = "WARN"

    requests_raw = data.get("RPCRequests", "")
    users_raw = data.get("UserCount", "")
    active_users_raw = data.get("ActiveUserCount", "")

    requests_val = 0
    if requests_raw != "" and requests_raw != None:
        requests_val = int(requests_raw)
    users_val = 0
    if users_raw != "" and users_raw != None:
        users_val = int(users_raw)
    active_users_val = 0
    if active_users_raw != "" and active_users_raw != None:
        active_users_val = int(active_users_raw)

    req_warn = req_levels[0] if len(req_levels) >= 1 else 30
    req_crit = req_levels[1] if len(req_levels) >= 2 else 40
    requests_state = "OK"
    if requests_val >= req_crit:
        requests_state = "CRIT"
    elif requests_val >= req_warn:
        requests_state = "WARN"

    overall_state = "OK"
    for s in [latency_state, requests_state]:
        if s == "CRIT":
            overall_state = "CRIT"
        elif s == "WARN" and overall_state != "CRIT":
            overall_state = "WARN"

    metrics = {
        "average_latency_s": latency_val,
        "requests_per_sec": requests_val,
        "current_users": users_val,
        "active_users": active_users_val,
    }

    msg = "Latency: %fs, Requests: %d/sec, Users: %d, Active: %d" % (
        latency_val, requests_val, users_val, active_users_val)

    return {"changed": False, "msg": msg,
            "data": {"state": overall_state, "metrics": metrics, "details": ""}}


def detect_exchange(ctx):
    res = ctx.run(["powershell", "-Command",
        "Get-Service -Name MSExchangeIS -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count"],
        mutates=False)
    if res.rc == 0 and res.stdout.strip() not in ("", "0"):
        return True
    return False


def read_exchange_counters(ctx):
    res = ctx.run(["powershell", "-Command",
        "$d=get-counter -Counter '\\RPC Client Access\\Average Latency','\\RPC Client Access\\RPC Requests','\\RPC Client Access\\User Count','\\RPC Client Access\\Active User Count' -ErrorAction SilentlyContinue; if($d){$d.CounterSamples | ForEach-Object {'{0}={1}'-f $_.Path.Split('\\')[-1],$_.CookedValue}}"],
        mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return None
    data = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split("=", 1)
        if len(parts) == 2:
            data[parts[0]] = parts[1]
    if len(data) == 0:
        return None
    return data