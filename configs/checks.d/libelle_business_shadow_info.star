def _size_to_mb(size_str):
    size_str = size_str.strip()
    if size_str.endswith("MB"):
        val_str = size_str[:-2]
        return int(float(val_str)) if val_str.replace(".", "").replace("-", "").isdigit() or val_str == "-" else 0
    elif size_str.endswith("GB"):
        val_str = size_str[:-2]
        return int(float(val_str)) * 1024 if val_str.replace(".", "").replace("-", "").isdigit() or val_str == "-" else 0
    elif size_str.endswith("TB"):
        val_str = size_str[:-2]
        return int(float(val_str)) * 1024 * 1024 if val_str.replace(".", "").replace("-", "").isdigit() or val_str == "-" else 0
    elif size_str.endswith("PB"):
        val_str = size_str[:-2]
        return int(float(val_str)) * 1024 * 1024 * 1024 if val_str.replace(".", "").replace("-", "").isdigit() or val_str == "-" else 0
    elif size_str.endswith("EB"):
        val_str = size_str[:-2]
        return int(float(val_str)) * 1024 * 1024 * 1024 * 1024 if val_str.replace(".", "").replace("-", "").isdigit() or val_str == "-" else 0
    # Plain number (MB assumed)
    val_str = size_str
    return int(float(val_str)) if val_str.replace(".", "").replace("-", "").isdigit() or val_str == "-" else 0

def _parse_section(lines):
    parsed = {}
    for line in lines:
        if not line:
            continue
        idx = line.find(":")
        if idx == -1:
            continue
        key = line[:idx].strip()
        value = line[idx+1:].strip()
        
        # Host
        if key.startswith("Host"):
            parsed["host"] = value
        # Start-Time
        elif key.startswith("Start-Time"):
            parsed["start_time"] = value
        # Release
        elif key == "Release":
            parsed["release"] = value
        # Status
        elif key.startswith("Status"):
            parsed["libelle_status"] = value
        # Process info: trdrecover or trdarchiver
        elif key.startswith("trdrecover") or key.startswith("trdarchiver"):
            # Process line format: "trdrecover   : Pid ... Timestamp ... Type ..."
            # We extract process name and status from the part after the colon and whitespace
            rest = value.strip()
            tokens = rest.split()
            if len(tokens) >= 4:
                # e.g., "trdrecover   : 2556268  22.05.2014 17:36:34  RUN"
                # tokens[0] might be "trdrecover" with extra space, tokens[-1] is status
                parsed["process"] = tokens[0].strip()
                # status is the last token
                parsed["process_status"] = tokens[-1]
        # Archive-Dir total
        elif key.startswith("Archive-Dir total"):
            parsed["arch_total_mb"] = _size_to_mb(value)
        # Archive-Dir free
        elif key.startswith("Archive-Dir free"):
            parsed["arch_free_mb"] = _size_to_mb(value)
    return parsed

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check-mk-agent/local/libelle_business_shadow"], mutates=False)
        # If agent output not available, try local file or fallback
        if not res.stdout:
            # Try fallback to common agent section source: /var/lib/check-mk-agent/agent-local/libelle_business_shadow
            res = ctx.run(["cat", "/var/lib/check-mk-agent/agent-local/libelle_business_shadow"], mutates=False)
        if not res.stdout:
            # Fallback: no data, return empty discovery
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        parsed = _parse_section(lines)
        
        out = []
        
        # Info check: single service
        out.append({"item": "", "params": {}, "metrics": []})
        
        # Status check: single service
        if "libelle_status" in parsed:
            out.append({"item": "", "params": {}, "metrics": []})
        
        # Process check: single service
        if "process" in parsed:
            out.append({"item": "", "params": {}, "metrics": []})
        
        # Archive dir: single item service
        if "arch_total_mb" in parsed and "arch_free_mb" in parsed:
            out.append({"item": "Archive Dir", "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d services" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/libelle_business_shadow"], mutates=False)
    if not res.stdout:
        res = ctx.run(["cat", "/var/lib/check-mk-agent/agent-local/libelle_business_shadow"], mutates=False)
    if not res.stdout:
        return {"changed": False, "msg": "no agent data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    parsed = _parse_section(lines)
    
    # Determine which service/item this is based on discovery pattern
    if item == "":
        # First service: Info check
        message = "Libelle Business Shadow"
        if "host" in parsed:
            message += ", Host: %s" % parsed["host"]
        if "release" in parsed:
            message += ", Release: %s" % parsed["release"]
        if "start_time" in parsed:
            message += ", Start Time: %s" % parsed["start_time"]
        return {"changed": False, "msg": message,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    
    # Status check (item == "")
    if item == "" and "libelle_status" in parsed:
        status = parsed["libelle_status"]
        message = "Status is: %s" % status
        state = "OK" if status == "RUN" else "CRIT"
        return {"changed": False, "msg": message,
                "data": {"state": state, "metrics": {}, "details": ""}}
    
    # Process check (item == "")
    if item == "" and "process" in parsed:
        process = parsed["process"]
        status = parsed["process_status"]
        message = "Active Process is: %s, Status: %s" % (process, status)
        state = "OK" if status == "RUN" else "CRIT"
        return {"changed": False, "msg": message,
                "data": {"state": state, "metrics": {}, "details": ""}}
    
    # Archive dir check (item == "Archive Dir")
    if item == "Archive Dir":
        if not ("arch_total_mb" in parsed and "arch_free_mb" in parsed):
            return {"changed": False, "msg": "no archive dir info available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        arch_total = parsed["arch_total_mb"]
        arch_free = parsed["arch_free_mb"]
        arch_used = arch_total - arch_free
        used_pct = int(float(arch_used) / arch_total * 100) if arch_total > 0 else 0
        warn = params.get("warn", 80.0)
        crit = params.get("crit", 90.0)
        
        state = "CRIT" if used_pct >= crit else ("WARN" if used_pct >= warn else "OK")
        
        # Build message
        msg = "Archive Dir: %d MB total, %d MB free (%d%% used)" % (arch_total, arch_free, used_pct)
        
        return {"changed": False, "msg": msg,
                "data": {"state": state,
                         "metrics": {"size": arch_total, "used": arch_used, "used_percent": used_pct, "free": arch_free},
                         "details": ""}}
    
    # Fallback for unknown item
    return {"changed": False, "msg": "unknown item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}