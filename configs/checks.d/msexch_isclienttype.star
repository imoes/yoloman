def _safe_int(s):
    if s == None or not s.strip().isdigit():
        return None
    return int(s.strip())

def _split_csv(s):
    parts = []
    for p in s.split(","):
        parts.append(p.strip())
    return parts

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["which", "wmic"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no wmi client available", "data": {"discovery": []}}
        
        res = ctx.run([
            "wmic", "--user", params.get("user", ""), "--password", params.get("password", ""),
            "--host", params.get("host", "localhost"),
            "Path", "Win32_PerfRawData_ESE_RPCOperations", "Get", "Name", "RPCAverageLatency", "RPCRequests",
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no exchange is client type data", "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        instances = []
        for line in lines:
            parts = _split_csv(line)
            if len(parts) >= 3 and parts[0] not in ("Name", ""):
                instances.append(parts[0])
        
        discovery = []
        for inst in instances:
            discovery.append({
                "item": inst,
                "params": {
                    "store_latency_s": (0.04, 0.05),
                    "clienttype_latency_s": (0.04, 0.05),
                    "clienttype_requests": (60, 70),
                },
                "metrics": ["average_latency_s", "requests_per_sec"],
            })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }
    
    item = params.get("item", "")
    
    res = ctx.run(["which", "wmic"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "no wmi client available for exchange is client type check",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    res = ctx.run([
        "wmic", "--user", params.get("user", ""), "--password", params.get("password", ""),
        "--host", params.get("host", "localhost"),
        "Path", "Win32_PerfRawData_ESE_RPCOperations", "Get", "Name", "RPCAverageLatency", "RPCRequests",
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no exchange is client type data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    lines = res.stdout.splitlines()
    match = None
    for line in lines:
        parts = _split_csv(line)
        if len(parts) >= 3 and parts[0] == item:
            match = parts
            break
    
    if match == None:
        return {
            "changed": False,
            "msg": "exchange is client type instance '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    latency_raw = _safe_int(match[1])
    if latency_raw == None:
        return {
            "changed": False,
            "msg": "failed to parse RPCAverageLatency value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    latency_s = latency_raw * 0.001
    
    requests_raw = _safe_int(match[2])
    if requests_raw == None:
        return {
            "changed": False,
            "msg": "failed to parse RPCRequests value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    latency_levels = params.get("clienttype_latency_s", (0.04, 0.05))
    latency_warn = latency_levels[0]
    latency_crit = latency_levels[1]
    
    requests_levels = params.get("clienttype_requests", (60, 70))
    requests_warn = requests_levels[0]
    requests_crit = requests_levels[1]
    
    if latency_s >= latency_crit:
        latency_state = "CRIT"
    elif latency_s >= latency_warn:
        latency_state = "WARN"
    else:
        latency_state = "OK"
    
    if requests_raw >= requests_crit:
        requests_state = "CRIT"
    elif requests_raw >= requests_warn:
        requests_state = "WARN"
    else:
        requests_state = "OK"
    
    state_priority = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    overall_state = latency_state
    if state_priority[requests_state] > state_priority[overall_state]:
        overall_state = requests_state
    
    msg = "Average latency: %fs, RPC Requests/sec: %d" % (latency_s, requests_raw)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": {"average_latency_s": latency_s, "requests_per_sec": requests_raw},
            "details": "",
        },
    }