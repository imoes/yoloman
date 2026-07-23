def _translate_dev_status(status_str):
    _STATUS_MAP = {
        "1": ("WARN", "other"),
        "2": ("UNKNOWN", "unknown"),
        "3": ("OK", "OK"),
        "4": ("WARN", "non critical upper"),
        "5": ("CRIT", "critical upper"),
        "6": ("CRIT", "non recoverable upper"),
        "7": ("WARN", "non critical lower"),
        "8": ("CRIT", "critical lower"),
        "9": ("CRIT", "non recoverable lower"),
        "10": ("CRIT", "failed"),
    }
    return _STATUS_MAP.get(status_str, ("UNKNOWN", "unknown[" + status_str + "]"))


def _validate_levels(dev_warn, dev_crit):
    crit = None
    warn = None
    
    if dev_crit != "" and dev_crit != "-99":
        is_num = True
        for c in dev_crit:
            if c != '-' and not (c >= '0' and c <= '9'):
                is_num = False
        if is_num:
            crit = float(dev_crit)
    
    if dev_warn != "" and dev_warn != "-99":
        is_num = True
        for c in dev_warn:
            if c != '-' and not (c >= '0' and c <= '9'):
                is_num = False
        if is_num:
            warn = float(dev_warn)
    elif crit != None:
        warn = crit
    
    return (warn, crit)


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        base_oid = ".1.3.6.1.4.1.7244.1.2.1.3.5.1"
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1",
            base_oid + ".2",
            base_oid + ".3",
            base_oid + ".4",
            base_oid + ".6",
            base_oid + ".7",
            base_oid + ".8",
            base_oid + ".9"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        data = {}
        
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_full = parts[0].strip()
            value_raw = parts[1].strip()
            
            idx = oid_full.rsplit(".", 1)
            if len(idx) < 2:
                continue
            idx_suffix = idx[1]
            
            base_oid_parts = idx[0].rsplit(".", 1)
            if len(base_oid_parts) < 2:
                continue
            oid_base_str = base_oid_parts[1]
            oid_base = 0
            is_digit = True
            for c in oid_base_str:
                if not (c >= '0' and c <= '9'):
                    is_digit = False
            if is_digit:
                oid_base = int(oid_base_str)
            
            if value_raw.startswith('"'):
                value_raw = value_raw.strip('"')
                value_raw = value_raw.replace("\x01", "")
            else:
                value_raw = value_raw.strip().strip('"')
            
            if idx_suffix not in data:
                data[idx_suffix] = {}
            data[idx_suffix][oid_base] = value_raw
        
        items = []
        for idx_suffix in sorted(data.keys(), key=lambda x: int(x) if x.isdigit() else 0):
            rec = data[idx_suffix]
            if not rec:
                continue
            
            dev_name = rec.get(3, "")
            dev_status = rec.get(2, "")
            
            if not dev_name:
                continue
            
            dev_value_str = rec.get(4, "")
            dev_value = None
            if dev_value_str != "" and dev_value_str != "-99":
                is_num = True
                for c in dev_value_str:
                    if c != '-' and c != '.' and not (c >= '0' and c <= '9'):
                        is_num = False
                if is_num:
                    dev_value = float(dev_value_str)
            
            upper_warn, upper_crit = _validate_levels(rec.get(7, ""), rec.get(6, ""))
            lower_warn, lower_crit = _validate_levels(rec.get(8, ""), rec.get(9, ""))
            
            suggested_params = {}
            if upper_warn != None or upper_crit != None:
                suggested_params["levels"] = (upper_warn, upper_crit)
            if lower_warn != None or lower_crit != None:
                suggested_params["levels_lower"] = (lower_warn, lower_crit)
            
            items.append({
                "item": dev_name,
                "params": suggested_params,
                "metrics": ["voltage"]
            })
        
        return {"changed": False, "msg": "discovered %d voltage sensors" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    base_oid = ".1.3.6.1.4.1.7244.1.2.1.3.5.1"
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1",
        base_oid + ".2",
        base_oid + ".3",
        base_oid + ".4",
        base_oid + ".6",
        base_oid + ".7",
        base_oid + ".8",
        base_oid + ".9"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    data = {}
    
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        value_raw = parts[1].strip()
        
        idx = oid_full.rsplit(".", 1)
        if len(idx) < 2:
            continue
        idx_suffix = idx[1]
        
        base_oid_parts = idx[0].rsplit(".", 1)
        if len(base_oid_parts) < 2:
            continue
        oid_base_str = base_oid_parts[1]
        oid_base = 0
        is_digit = True
        for c in oid_base_str:
            if not (c >= '0' and c <= '9'):
                is_digit = False
        if is_digit:
            oid_base = int(oid_base_str)
        
        if value_raw.startswith('"'):
            value_raw = value_raw.strip('"').replace("\x01", "")
        else:
            value_raw = value_raw.strip().strip('"')
        
        if idx_suffix not in data:
            data[idx_suffix] = {}
        data[idx_suffix][oid_base] = value_raw
    
    item_found = None
    for idx_suffix in data.keys():
        rec = data[idx_suffix]
        dev_name = rec.get(3, "").strip()
        if dev_name == item:
            item_found = rec
            break
    
    if item_found == None:
        return {"changed": False, "msg": "voltage sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    dev_status = item_found.get(2, "")
    dev_value_str = item_found.get(4, "")
    upper_warn_str = item_found.get(7, "")
    upper_crit_str = item_found.get(6, "")
    lower_warn_str = item_found.get(8, "")
    lower_crit_str = item_found.get(9, "")
    
    status_tuple = _translate_dev_status(dev_status)
    state = status_tuple[0]
    status_msg = status_tuple[1]
    
    dev_value = None
    if dev_value_str != "" and dev_value_str != "-99":
        is_num = True
        for c in dev_value_str:
            if c != '-' and c != '.' and not (c >= '0' and c <= '9'):
                is_num = False
        if is_num:
            dev_value = float(dev_value_str)
    
    warn = params.get("levels", None)
    crit = params.get("levels", None)
    if warn == None and crit == None:
        warn, crit = _validate_levels(upper_warn_str, upper_crit_str)
    
    warn_lower = params.get("levels_lower", None)
    crit_lower = params.get("levels_lower", None)
    if warn_lower == None and crit_lower == None:
        warn_lower, crit_lower = _validate_levels(lower_warn_str, lower_crit_str)
    
    if dev_value != None:
        if crit != None and dev_value >= crit:
            state = "CRIT"
        elif warn != None and dev_value >= warn:
            state = "WARN"
        
        if crit_lower != None and dev_value <= crit_lower:
            state = "CRIT"
        elif warn_lower != None and dev_value <= warn_lower:
            state = "WARN"
    
    summary_parts = ["Status: " + status_msg]
    if dev_value != None:
        summary_parts.append("Value: %f V" % dev_value)
    summary = ", ".join(summary_parts)
    
    metrics = {}
    if dev_value != None:
        metrics["voltage"] = dev_value
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}