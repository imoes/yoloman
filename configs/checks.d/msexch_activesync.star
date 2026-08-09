def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Probe for Exchange ActiveSync performance counters
        res = ctx.run([
            "typeperf", "-s", params.get("host", "localhost"),
            "\\MSExchange ActiveSync\\Requests/sec"
        ], mutates=False)
        if res.rc == 127:
            # typeperf not found
            return {"changed": False, "msg": "not installed", "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "discovery failed", "data": {"discovery": []}}
        # If we get here, the counter exists - single service check (item="")
        return {"changed": False, "msg": "discovered", "data": {"discovery": [
            {"item": "", "params": {}, "metrics": ["requests_per_sec"]}
        ]}}
    
    # Check mode
    res = ctx.run([
        "typeperf", "-s", params.get("host", "localhost"),
        "\\MSExchange ActiveSync\\Requests/sec"
    ], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "typeperf not installed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "counter query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse typeperf output - format: "timestamp,value"
    lines = res.stdout.splitlines()
    # typeperf outputs header line, then data lines like: "2019-01-15","0.000000"
    if len(lines) < 2:
        return {"changed": False, "msg": "no data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    last_line = lines[-1]
    parts = last_line.split(",")
    if len(parts) < 2:
        return {"changed": False, "msg": "parse error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_str = parts[-1].strip().strip('"')
    if not value_str:
        return {"changed": False, "msg": "empty value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    rate = float(value_str)
    # No thresholds defined in the check plugin, so state is OK
    return {"changed": False, "msg": "Requests/sec: %f" % rate,
            "data": {"state": "OK", "metrics": {"requests_per_sec": rate}, "details": ""}}