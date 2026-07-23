def main(ctx, params):
    # Determine mode: discovery or check
    if params.get("_discover"):
        # Run nvidia-smi to get XML output
        res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "nvidia-smi failed or returned empty output",
                    "data": {"discovery": []}}
        
        # Extract GPU IDs using string operations
        gpu_ids = []
        xml_content = res.stdout
        start_idx = 0
        while True:
            idx = xml_content.find("<gpu id=", start_idx)
            if idx == -1:
                break
            id_start = xml_content.find('"', idx) + 1
            id_end = xml_content.find('"', id_start)
            if id_start > 0 and id_end > id_start:
                gpu_id = xml_content[id_start:id_end]
                gpu_ids.append(gpu_id)
            start_idx = idx + 1
        
        # Build discovery list
        discovery_items = []
        for gpu_id in gpu_ids:
            discovery_items.append({
                "item": gpu_id,
                "params": {
                    "levels_total": None,
                    "levels_bar1": None,
                    "levels_fb": None
                },
                "metrics": ["total_memory_used_percent", "fb_mem_usage_used", "bar1_mem_usage_used"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d GPUs" % len(gpu_ids),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run(["nvidia-smi", "-q", "-x"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "nvidia-smi failed or returned empty output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    xml_content = res.stdout
    
    # Find the specific GPU block by ID
    gpu_block = None
    start_idx = 0
    while True:
        idx = xml_content.find("<gpu id=", start_idx)
        if idx == -1:
            break
        id_start = xml_content.find('"', idx) + 1
        id_end = xml_content.find('"', id_start)
        if id_start > 0 and id_end > id_start:
            gpu_id = xml_content[id_start:id_end]
            if gpu_id == item:
                block_start = idx
                block_end = xml_content.find("</gpu>", block_start)
                if block_end != -1:
                    gpu_block = xml_content[block_start:block_end + 6]
                    break
        start_idx = idx + 1
    
    if gpu_block == None:
        return {"changed": False, "msg": "GPU not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Helper function to extract float value from XML element
    def get_float_value(block, tag_name, unit=None):
        tag_start = "<%s>" % tag_name
        tag_end = "</%s>" % tag_name
        idx = block.find(tag_start)
        if idx == -1:
            return None
        val_start = idx + len(tag_start)
        val_end = block.find(tag_end, val_start)
        if val_end == -1:
            return None
        value_str = block[val_start:val_end].strip()
        if value_str == "N/A" or value_str == "":
            return None
        if unit != None and value_str.endswith(unit):
            value_str = value_str[:-len(unit)].strip()
        # Guard instead of try/except: validate numeric format
        check_str = value_str.replace("-", "").replace(".", "")
        if check_str == "" or not check_str.isdigit():
            return None
        # Manual float conversion using split on decimal point
        parts = value_str.split(".")
        if len(parts) == 1:
            return float(int(parts[0]))
        elif len(parts) == 2 and parts[0].lstrip("-").isdigit() and parts[1].isdigit():
            # Compute fractional part: int(parts[1]) / (10^len(parts[1]))
            denominator = 1
            for _ in range(len(parts[1])):
                denominator = denominator * 10
            return float(int(parts[0])) + float(int(parts[1])) / denominator
        else:
            return None
    
    # Extract memory values
    fb_total = get_float_value(gpu_block, "fb_memory_usage/total", "MiB")
    fb_used = get_float_value(gpu_block, "fb_memory_usage/used", "MiB")
    fb_free = get_float_value(gpu_block, "fb_memory_usage/free", "MiB")
    
    bar1_total = get_float_value(gpu_block, "bar1_memory_usage/total", "MiB")
    bar1_used = get_float_value(gpu_block, "bar1_memory_usage/used", "MiB")
    bar1_free = get_float_value(gpu_block, "bar1_memory_usage/free", "MiB")
    
    # Validate required values exist
    if (fb_total == None or fb_used == None or 
        bar1_total == None or bar1_used == None):
        return {"changed": False, "msg": "memory information incomplete",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Calculate totals
    sum_total = fb_total + bar1_total
    sum_used = fb_used + bar1_used
    
    # Calculate percentages
    total_percent = (sum_used / sum_total * 100) if sum_total > 0 else 0.0
    fb_percent = (fb_used / fb_total * 100) if fb_total > 0 else 0.0
    bar1_percent = (bar1_used / bar1_total * 100) if bar1_total > 0 else 0.0
    
    # Get thresholds
    levels_total = params.get("levels_total")
    levels_bar1 = params.get("levels_bar1")
    levels_fb = params.get("levels_fb")
    
    # Determine state
    state = "OK"
    details_parts = []
    
    # Check total memory
    if levels_total != None:
        warn_val = levels_total[0]
        crit_val = levels_total[1]
        if crit_val != None and total_percent >= crit_val:
            state = "CRIT"
        elif warn_val != None and total_percent >= warn_val:
            state = "WARN" if state == "OK" else state
        details_parts.append("Total: %f%% used (%f/%f MiB)" % (
            total_percent, sum_used, sum_total))
    else:
        details_parts.append("Total: %f%% used (%f/%f MiB)" % (
            total_percent, sum_used, sum_total))
    
    # Check FB memory
    if levels_fb != None:
        warn_val = levels_fb[0]
        crit_val = levels_fb[1]
        if crit_val != None and fb_percent >= crit_val:
            state = "CRIT"
        elif warn_val != None and fb_percent >= warn_val:
            state = "WARN" if state == "OK" else state
        details_parts.append("FB: %f%% used (%f/%f MiB)" % (
            fb_percent, fb_used, fb_total))
    else:
        details_parts.append("FB: %f%% used (%f/%f MiB)" % (
            fb_percent, fb_used, fb_total))
    
    # Check BAR1 memory
    if levels_bar1 != None:
        warn_val = levels_bar1[0]
        crit_val = levels_bar1[1]
        if crit_val != None and bar1_percent >= crit_val:
            state = "CRIT"
        elif warn_val != None and bar1_percent >= warn_val:
            state = "WARN" if state == "OK" else state
        details_parts.append("BAR1: %f%% used (%f/%f MiB)" % (
            bar1_percent, bar1_used, bar1_total))
    else:
        details_parts.append("BAR1: %f%% used (%f/%f MiB)" % (
            bar1_percent, bar1_used, bar1_total))
    
    # Build metrics dict
    metrics = {
        "total_memory_used_percent": total_percent,
        "fb_mem_usage_used": fb_used,
        "fb_mem_usage_free": fb_free,
        "fb_mem_usage_total": fb_total,
        "bar1_mem_usage_used": bar1_used,
        "bar1_mem_usage_free": bar1_free,
        "bar1_mem_usage_total": bar1_total
    }
    
    return {
        "changed": False,
        "msg": ", ".join(details_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }