# ===== Starlark check module: fortigate_ips =====
# Translation of Checkmk's fortigate_ips check plugin

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.12356.101.9.2.1.1"
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            value_str = parts[1].strip()
            if value_str.startswith("INTEGER: "):
                value_str = value_str[9:]
            elif not (value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit())):
                continue
            
            # Parse OID ending (the item key)
            oid_part = parts[0].strip()
            item_key = oid_part.rsplit(".", 1)[-1]
            if not item_key.isdigit():
                continue
            
            items.append({
                "item": item_key,
                "params": {"detections": (100.0, 300.0)},
                "metrics": ["fortigate_detection_rate", "fortigate_blocking_rate"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d IPS entries" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.12356.101.9.2.1.1"
    ], mutates=False)
    
    detected = None
    blocked = None
    count = 0
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        if not oid_part.startswith(".1.3.6.1.4.1.12356.101.9.2.1.1."):
            continue
        suffix = oid_part.rsplit(".", 1)[-1]
        if suffix != item:
            continue
        
        value_str = parts[1].strip()
        if value_str.startswith("INTEGER: "):
            value_str = value_str[9:]
        
        if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
            val = int(value_str)
            if count == 0:
                detected = val
            elif count == 1:
                blocked = val
                break
            count = count + 1
    
    if detected == None or blocked == None:
        return {
            "changed": False,
            "msg": "no data for IPS entry %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Read previous values for rate calculation
    vs_path = "/tmp/checkmk_vs_fortigate_ips_" + item
    old_data = ""
    if ctx.file_exists(vs_path):
        old_data = ctx.file_read(vs_path).strip()
    
    old_time = 0.0
    old_detected = 0
    old_blocked = 0
    
    if old_data != "":
        old_parts = old_data.split(",")
        if len(old_parts) == 3:
            old_time_str = old_parts[0]
            if old_time_str.isdigit() or (old_time_str.startswith("-") and old_time_str[1:].isdigit()):
                old_time = float(old_time_str)
            if old_parts[1].isdigit() or (old_parts[1].startswith("-") and old_parts[1][1:].isdigit()):
                old_detected = int(old_parts[1])
            if old_parts[2].isdigit() or (old_parts[2].startswith("-") and old_parts[2][1:].isdigit()):
                old_blocked = int(old_parts[2])
    
    now = 0.0
    date_res = ctx.run(["date", "+%s"], mutates=False)
    now_str = date_res.stdout.strip()
    if now_str.isdigit() or (now_str.startswith("-") and now_str[1:].isdigit()):
        now = float(now_str)
    
    time_delta = now - old_time
    detection_rate = 0.0
    blocking_rate = 0.0
    
    if time_delta > 0 and time_delta < 86400:
        detection_rate = float(detected - old_detected) / time_delta
        blocking_rate = float(blocked - old_blocked) / time_delta
    
    # Save new values
    new_data = str(now) + "," + str(detected) + "," + str(blocked)
    ctx.file_write(vs_path, new_data)
    
    # Apply thresholds
    params_detections = params.get("detections", (100.0, 300.0))
    warn_detect = 100.0
    crit_detect = 300.0
    if len(params_detections) > 0:
        warn_detect = params_detections[0]
    if len(params_detections) > 1:
        crit_detect = params_detections[1]
    
    state = "OK"
    if detection_rate >= crit_detect:
        state = "CRIT"
    elif detection_rate >= warn_detect:
        state = "WARN"
    
    msg = "IPS entry %s: Detection rate: %f/s, Blocking rate: %f/s" % (item, detection_rate, blocking_rate)
    if state != "OK":
        msg = "IPS entry %s: %s: Detection rate: %f/s, Blocking rate: %f/s" % (item, state, detection_rate, blocking_rate)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "fortigate_detection_rate": detection_rate,
                "fortigate_blocking_rate": blocking_rate
            },
            "details": ""
        }
    }
