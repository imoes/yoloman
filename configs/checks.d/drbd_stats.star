# DRBD stats check module for yolo-man agent
# Reads /proc/drbd directly to gather DRBD statistics per device

def _parse_drbd_count(raw):
    """Parse a DRBD counter value (handles DRBD 9.x bracket notation)."""
    if raw.startswith("[") and raw.endswith("]"):
        parts = raw[1:-1].split(";")
        total = 0
        for p in parts:
            if p.isdigit():
                total += int(p)
        return total
    if raw.isdigit():
        return int(raw)
    return 0

def main(ctx, params):
    if params.get("_discover"):
        # Read /proc/drbd to discover DRBD devices
        res = ctx.run(["cat", "/proc/drbd"], mutates=False)
        out = []
        lines = res.stdout.split("\n")
        for line in lines:
            stripped = line.strip()
            # Look for lines starting with digit followed by colon (device specifier)
            if stripped != "" and stripped[0].isdigit() and stripped.find(":") == 1:
                device_num = stripped.split(":")[0]
                item_name = "drbd" + device_num
                # Add to discovery list with empty params (default thresholds)
                out.append({"item": item_name, "params": {}, 
                            "metrics": ["activity_log_updates", "bit_map_updates", "local_count_requests", 
                                       "pending_requests", "unacknowledged_requests", "application_pending_requests", 
                                       "epoch_objects", "kb_out_of_sync", "write_order"]})
        return {"changed": False, "msg": "discovered %d DRBD devices" % len(out),
                "data": {"discovery": out}}

    # Check mode: examine specific device
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no device specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run(["cat", "/proc/drbd"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read /proc/drbd",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse /proc/drbd for the specified device
    lines = res.stdout.split("\n")
    in_block = False
    block_lines = []
    
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        # Find start of target device block
        if stripped[0].isdigit() and stripped.find(":") == 1:
            device_num = stripped.split(":")[0]
            target = item.replace("drbd", "")
            if device_num == target:
                in_block = True
                continue
            elif in_block:
                # Another device block started - we're done with our target
                break
        if in_block:
            block_lines.append(line)
    
    if not in_block and item.replace("drbd", "") not in res.stdout:
        return {"changed": False, "msg": "device %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the device block into key-value pairs
    parsed = {}
    for line in block_lines:
        parts = line.strip().split(":")
        if len(parts) >= 2:
            key = parts[0].strip()
            value = parts[1].strip()
            # Handle multiple values after colon (e.g., ro:Primary/Secondary)
            if len(parts) > 2:
                value = ":".join(parts[1:]).strip()
            parsed[key] = value
    
    # Check for unconfigured device
    if parsed.get("cs") == "Unconfigured":
        return {"changed": False, "msg": 'device "%s" is Unconfigured' % item,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    # Extract metrics
    metrics = {}
    details_parts = []
    
    # Required metrics from drbd_stats check
    metric_specs = [
        ("al", "activity log updates"),
        ("bm", "bit map updates"),
        ("lo", "local count requests"),
        ("pe", "pending requests"),
        ("ua", "unacknowledged requests"),
        ("ap", "application pending requests"),
        ("ep", "epoch objects"),
        ("wo", "write order"),
        ("oos", "kb out of sync"),
    ]
    
    for key, label in metric_specs:
        raw_value = parsed.get(key, "0")
        value = _parse_drbd_count(raw_value)
        metric_name = label.replace(" ", "_")
        metrics[metric_name] = value
    
    # Format details for connection state (always present)
    cs = parsed.get("cs", "Unknown")
    ro = parsed.get("ro", "Unknown/Unknown")
    ds = parsed.get("ds", "Unknown/Unknown")
    details_parts.append("Connection State: %s" % cs)
    details_parts.append("Roles: %s" % ro)
    details_parts.append("Disk States: %s" % ds)
    
    # Return final result
    return {"changed": False, "msg": "%s: cs=%s" % (item, cs),
            "data": {"state": "OK", "metrics": metrics, 
                    "details": "; ".join(details_parts)}}