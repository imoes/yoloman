def main(ctx, params):
    # Constants for SNMP base OIDs and metric keys
    MCAFEE_BASE_OID = ".1.3.6.1.4.1.1230.2.7.2"
    SKYHIGH_BASE_OID = ".1.3.6.1.4.1.59732.2.7.2"
    
    # Check mode: discovery or check
    if params.get("_discover"):
        # Discovery: detect device type by system description
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), 
                      "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"], 
                      mutates=False)
        sys_desc = res.stdout.strip().split(" = ") if res.stdout.strip() else []
        sys_desc_text = ""
        if len(sys_desc) > 1:
            desc_parts = sys_desc[1].split(": ", 1)
            if len(desc_parts) > 1:
                sys_desc_text = desc_parts[1].lower()
        
        # Determine which base OID to use
        base_oid = SKYHIGH_BASE_OID if "skyhigh secure web gateway" in sys_desc_text else MCAFEE_BASE_OID
        
        # Fetch all three metrics
        http_val = _snmp_get_value(ctx, params, base_oid + ".2.1")
        httpv2_val = _snmp_get_value(ctx, params, base_oid + ".3.1")
        https_val = _snmp_get_value(ctx, params, base_oid + ".6.1")
        
        services = []
        if http_val != None:
            services.append({
                "item": "HTTP",
                "params": {
                    "client_requests_http": [500, 1000]
                },
                "metrics": ["requests_per_second"]
            })
        if https_val != None:
            services.append({
                "item": "HTTPS",
                "params": {
                    "client_requests_https": [500, 1000]
                },
                "metrics": ["requests_per_second"]
            })
        if httpv2_val != None:
            services.append({
                "item": "HTTPv2",
                "params": {
                    "client_requests_httpv2": [500, 1000]
                },
                "metrics": ["requests_per_second"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d services" % len(services),
            "data": {
                "discovery": services
            }
        }
    
    # Check mode: handle specific item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Get parameter thresholds with defaults
    if item == "HTTP":
        levels = params.get("client_requests_http", [500, 1000])
        base_oid = _detect_base_oid(ctx, params)
        metric_val = _snmp_get_value(ctx, params, base_oid + ".2.1")
        metric_name = "http"
    elif item == "HTTPS":
        levels = params.get("client_requests_https", [500, 1000])
        base_oid = _detect_base_oid(ctx, params)
        metric_val = _snmp_get_value(ctx, params, base_oid + ".6.1")
        metric_name = "https"
    elif item == "HTTPv2":
        levels = params.get("client_requests_httpv2", [500, 1000])
        base_oid = _detect_base_oid(ctx, params)
        metric_val = _snmp_get_value(ctx, params, base_oid + ".3.1")
        metric_name = "httpv2"
    else:
        return {
            "changed": False,
            "msg": "unknown item: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Fetch the raw value and compute rate
    if metric_val == None:
        return {
            "changed": False,
            "msg": "no data for " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Use value_store to compute rate
    value_store_key = "webgateway_" + metric_name + "_requests"
    res = ctx.run(["date", "+%s"], mutates=False)
    now_str = res.stdout.strip()
    now = int(now_str) if now_str.isdigit() else 0
    
    # Get previous value
    prev = _get_value_store_value(ctx, value_store_key)
    if prev == None:
        return {
            "changed": False,
            "msg": "Can't compute rate.",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
    
    # Calculate rate
    delta = now - prev["timestamp"]
    if delta <= 0:
        return {
            "changed": False,
            "msg": "Can't compute rate.",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
    
    rate = float(metric_val - prev["value"]) / float(delta)
    
    # Apply thresholds: levels[0] = warn, levels[1] = crit
    state = "OK"
    if levels != None and len(levels) >= 2:
        if rate >= levels[1]:
            state = "CRIT"
        elif rate >= levels[0]:
            state = "WARN"
    
    # Update value store
    _set_value_store_value(ctx, value_store_key, {"timestamp": now, "value": metric_val})
    
    return {
        "changed": False,
        "msg": "%s Rate: %f/s" % (item, rate),
        "data": {
            "state": state,
            "metrics": {"requests_per_second": rate},
            "details": ""
        }
    }

def _detect_base_oid(ctx, params):
    # Detect device type by system description
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), 
                  "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"], 
                  mutates=False)
    sys_desc = res.stdout.strip().split(" = ") if res.stdout.strip() else []
    sys_desc_text = ""
    if len(sys_desc) > 1:
        desc_parts = sys_desc[1].split(": ", 1)
        if len(desc_parts) > 1:
            sys_desc_text = desc_parts[1].lower()
    
    return ".1.3.6.1.4.1.59732.2.7.2" if "skyhigh secure web gateway" in sys_desc_text else ".1.3.6.1.4.1.1230.2.7.2"

def _snmp_get_value(ctx, params, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost"), oid], mutates=False)
    if res.rc != 0:
        return None
    
    # Parse snmpget output: "<OID> = <TYPE>: <value>"
    lines = res.stdout.strip().splitlines()
    if len(lines) < 1:
        return None
    
    parts = lines[0].split(": ")
    if len(parts) < 2:
        return None
    value_str = parts[1].strip()
    
    # Extract numeric value
    value_parts = value_str.split(":", 1)
    if len(value_parts) < 2:
        return None
    value_str = value_parts[1].strip()
    
    return int(value_str) if value_str.isdigit() else None

def _get_value_store_value(ctx, key):
    # Use file-based value store via ctx.file_read
    path = "/tmp/checkmk_" + key
    if not ctx.file_exists(path):
        return None
    content = ctx.file_read(path)
    if content == "":
        return None
    # Parse JSON manually: {"timestamp": N, "value": N}
    data = json.decode(content)
    if type(data) == "dict" and data.get("timestamp") != None and data.get("value") != None:
        return {"timestamp": int(data["timestamp"]), "value": int(data["value"])}
    return None

def _set_value_store_value(ctx, key, value):
    path = "/tmp/checkmk_" + key
    ctx.file_write(path, json.encode(value), "0644")