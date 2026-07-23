def main(ctx, params):
    if params.get("_discover"):
        # Discover instances from the WMI table: msexch_isclienttype
        res = ctx.run(["wmic", "path", "Win32_PerfRawData_MicrosoftExchangeISClientType", "get", "Name,RPCAverageLatency,RPCAverageLatency_Base,RPCRequests,Timestamp_PerfTime,Frequency_PerfTime"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no data", "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False, "msg": "no data", "data": {"discovery": []}}
        
        items = []
        for line in lines[1:]:
            stripped = line.strip()
            if not stripped:
                continue
            fields = stripped.split()
            if len(fields) == 0:
                continue
            name = fields[0].strip('"')
            if name == "" or name == "_Total" or name == "__Total__" or name == "_Global":
                continue
            items.append({"item": name, "params": {}, "metrics": ["average_latency_s", "requests_per_sec"]})
        
        return {"changed": False, "msg": "discovered %d instances" % len(items), "data": {"discovery": items}}

    # Check mode for one instance
    item = params.get("item", "")
    res = ctx.run(["wmic", "path", "Win32_PerfRawData_MicrosoftExchangeISClientType", "where", "Name=\"" + item + "\"", "get", "RPCAverageLatency,RPCAverageLatency_Base,RPCRequests,Timestamp_PerfTime,Frequency_PerfTime"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no data for instance " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "no data for instance " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the single row of data (skip header)
    fields = lines[1].strip().split()
    if len(fields) < 5:
        return {"changed": False, "msg": "malformed data for instance " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    measure_str = fields[0]
    base_str = fields[1]
    requests_str = fields[2]
    timestamp_str = fields[3]
    frequency_str = fields[4]
    
    measure = int(measure_str) if measure_str.isdigit() else 0
    base = int(base_str) if base_str.isdigit() else 0
    requests = int(requests_str) if requests_str.isdigit() else 0
    timestamp = int(timestamp_str) if timestamp_str.isdigit() else 0
    frequency = int(frequency_str) if frequency_str.isdigit() else 0
    
    # Compute average latency (factor 0.001 as in source)
    factor = 0.001
    if base < 0:
        base = base + (1 << 32)
    if base == 0:
        avg_latency = 0.0
    else:
        avg_latency = float(measure) * factor / float(base)
    
    # Compute rate for RPCRequests (per-second)
    # With single sample we cannot compute rate; fallback to 0
    rate = 0.0

    # Thresholds from defaults: clienttype_latency_s = (0.04, 0.05), clienttype_requests = (60, 70)
    warn_latency = params.get("clienttype_latency_s", (0.04, 0.05))
    crit_latency = params.get("clienttype_latency_s", (0.04, 0.05))
    warn_latency_val = warn_latency[1] if type(warn_latency) == "list" else 0.05
    crit_latency_val = crit_latency[1] if type(crit_latency) == "list" else 0.05
    
    warn_requests = params.get("clienttype_requests", (60, 70))
    crit_requests = params.get("clienttype_requests", (60, 70))
    warn_requests_val = warn_requests[1] if type(warn_requests) == "list" else 70
    crit_requests_val = crit_requests[1] if type(crit_requests) == "list" else 70
    
    # Determine state for latency (upper levels)
    state = "OK"
    if avg_latency >= crit_latency_val:
        state = "CRIT"
    elif avg_latency >= warn_latency_val:
        state = "WARN"
    
    # Determine state for requests (upper levels)
    if rate >= crit_requests_val:
        state = "CRIT"
    elif rate >= warn_requests_val:
        state = "WARN"
    
    msg_parts = []
    msg_parts.append("Avg latency: %f s" % avg_latency)
    msg_parts.append("RPC req/s: %d" % int(rate))
    msg = ", ".join(msg_parts)
    
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"average_latency_s": avg_latency, "requests_per_sec": int(rate)}, "details": ""}}