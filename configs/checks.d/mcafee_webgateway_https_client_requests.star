def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.59732.2.7.2.6.1"
        ], mutates=False)
        
        https_value = None
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 3 and parts[-2] == ":":
                val_str = parts[-1]
                if val_str.isdigit():
                    https_value = int(val_str)
                    break
        
        if https_value != None:
            return {
                "changed": False,
                "msg": "discovered HTTPS client requests",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {
                                "client_requests_https": (500, 1000)
                            },
                            "metrics": ["requests_per_second"]
                        }
                    ]
                }
            }
        return {
            "changed": False,
            "msg": "no HTTPS client requests data available",
            "data": {"discovery": []}
        }
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.59732.2.7.2.6.1"
    ], mutates=False)
    
    https_value = None
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3 and parts[-2] == ":":
            val_str = parts[-1]
            if val_str.isdigit():
                https_value = int(val_str)
                break
    
    if https_value == None:
        return {
            "changed": False,
            "msg": "Can't compute rate - no HTTPS data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    levels_https = params.get("client_requests_https", (500, 1000))
    warn = levels_https[0]
    crit = levels_https[1]
    
    # Use ctx.facts() to get timestamp if available, otherwise fall back to current time
    current_time = int(ctx.facts().get("timestamp", 0))
    if current_time == 0:
        # Use current Unix timestamp via date command
        date_res = ctx.run(["date", "+%s"], mutates=False)
        current_time = int(date_res.stdout.strip()) if date_res.stdout.strip().isdigit() else 0
    
    prev_data = ctx.file_read("/tmp/yolo_mcafee_https_rate.json") if ctx.file_exists("/tmp/yolo_mcafee_https_rate.json") else "{}"
    
    if not prev_data:
        prev_data = "{}"
    
    prev = json.decode(prev_data) if prev_data else {}
    
    prev_val = prev.get("value", None)
    prev_time = prev.get("time", None)
    
    rate = 0.0
    if prev_val != None and prev_time != None and prev_time != current_time:
        delta = float(current_time - prev_time)
        if delta <= 0:
            delta = 1.0
        rate = float(https_value - prev_val) / delta
        if rate < 0:
            rate = 0.0
    
    new_data = {"value": https_value, "time": current_time}
    ctx.file_write("/tmp/yolo_mcafee_https_rate.json", json.encode(new_data))
    
    state = "OK"
    if rate >= crit:
        state = "CRIT"
    elif rate >= warn:
        state = "WARN"
    
    msg = "HTTPS Client Request Rate: %f/s" % rate
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"requests_per_second": rate},
            "details": ""
        }
    }