def main(ctx, params):
    # Read the MTR data file written by the agent
    mtr_path = "/var/lib/mknested/mtr.json"
    if not ctx.file_exists(mtr_path):
        return {"changed": False, "msg": "MTR data file not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    content = ctx.file_read(mtr_path)
    if not content.strip():
        return {"changed": False, "msg": "MTR data file empty",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = json.decode(content) if content.strip() else {}
    
    # Discovery mode
    if params.get("_discover"):
        items = []
        for hostname in section:
            items.append({"item": hostname, "params": {"pl": [10, 25], "rta": [150, 250], "rtstddev": [150, 250]},
                          "metrics": ["hops"]})
        return {"changed": False, "msg": "discovered %d targets" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    if section.get(item) == None:
        return {"changed": False, "msg": "Target not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    hops_raw = section.get(item)
    if len(hops_raw) == 0:
        return {"changed": False, "msg": "Insufficient data: No hop information available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse Hop objects: [name, pl, response_time, rta, rtmin, rtmax, rtstddev]
    hops = []
    for hop_data in hops_raw:
        if len(hop_data) < 7:
            continue
        pl_str = hop_data[1]
        pl_val = float(pl_str.replace("%", "").rstrip()) if pl_str.find("%") >= 0 else 0.0
        hops.append({
            "name": hop_data[0],
            "pl": pl_val,
            "response_time": float(hop_data[2]) / 1000.0 if hop_data[2].replace(".","").replace("-","").isdigit() else 0.0,
            "rta": float(hop_data[3]) / 1000.0 if hop_data[3].replace(".","").replace("-","").isdigit() else 0.0,
            "rtmin": float(hop_data[4]) / 1000.0 if hop_data[4].replace(".","").replace("-","").isdigit() else 0.0,
            "rtmax": float(hop_data[5]) / 1000.0 if hop_data[5].replace(".","").replace("-","").isdigit() else 0.0,
            "rtstddev": float(hop_data[6]) / 1000.0 if hop_data[6].replace(".","").replace("-","").isdigit() else 0.0,
        })
    
    if len(hops) == 0:
        return {"changed": False, "msg": "Insufficient data: No hop information available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract params with defaults
    pl_warn = params.get("pl", [10, 25])
    pl_warn_val = pl_warn[0] if len(pl_warn) > 0 else 10
    pl_crit_val = pl_warn[1] if len(pl_warn) > 1 else 25
    
    rta_warn = params.get("rta", [150, 250])
    rta_warn_val = rta_warn[0] / 1000.0 if len(rta_warn) > 0 else 0.15
    rta_crit_val = rta_warn[1] / 1000.0 if len(rta_warn) > 1 else 0.25
    
    rtstddev_warn = params.get("rtstddev", [150, 250])
    rtstddev_warn_val = rtstddev_warn[0] / 1000.0 if len(rtstddev_warn) > 0 else 0.15
    rtstddev_crit_val = rtstddev_warn[1] / 1000.0 if len(rtstddev_warn) > 1 else 0.25
    
    # Determine state
    state = "OK"
    msg_parts = ["Hops: %d" % len(hops)]
    details_parts = []
    
    # Non-last hops metrics
    metrics = {}
    for idx, hop in enumerate(hops[:-1]):
        hop_num = idx + 1
        metrics["hop_%d_rta" % hop_num] = hop["rta"]
        metrics["hop_%d_rtmin" % hop_num] = hop["rtmin"]
        metrics["hop_%d_rtmax" % hop_num] = hop["rtmax"]
        metrics["hop_%d_rtstddev" % hop_num] = hop["rtstddev"]
        metrics["hop_%d_response_time" % hop_num] = hop["response_time"]
        metrics["hop_%d_pl" % hop_num] = hop["pl"]
        details_parts.append("Hop %d: %s" % (hop_num, hop["name"]))
    
    # Last hop checks
    last_hop = hops[-1]
    last_idx = len(hops)
    last_hop_num = last_idx
    
    # Packet loss check
    pl = last_hop["pl"]
    if pl >= pl_crit_val:
        state = "CRIT"
        msg_parts.append("Packet loss %d%% (crit at %d%%)" % (pl, pl_crit_val * 100))
    elif pl >= pl_warn_val:
        if state == "OK":
            state = "WARN"
        msg_parts.append("Packet loss %d%% (warn at %d%%)" % (pl, pl_warn_val * 100))
    
    # RTA check
    rta = last_hop["rta"]
    if rta >= rta_crit_val:
        state = "CRIT"
        msg_parts.append("RTA %f ms (crit at %f ms)" % (rta * 1000, rta_crit_val * 1000))
    elif rta >= rta_warn_val:
        if state == "OK":
            state = "WARN"
        msg_parts.append("RTA %f ms (warn at %f ms)" % (rta * 1000, rta_warn_val * 1000))
    
    # RTSTDDEV check
    rtstddev = last_hop["rtstddev"]
    if rtstddev >= rtstddev_crit_val:
        state = "CRIT"
        msg_parts.append("RTSTDDEV %f ms (crit at %f ms)" % (rtstddev * 1000, rtstddev_crit_val * 1000))
    elif rtstddev >= rtstddev_warn_val:
        if state == "OK":
            state = "WARN"
        msg_parts.append("RTSTDDEV %f ms (warn at %f ms)" % (rtstddev * 1000, rtstddev_warn_val * 1000))
    
    # Add last hop metrics
    metrics["hop_%d_rta" % last_hop_num] = last_hop["rta"]
    metrics["hop_%d_rtmin" % last_hop_num] = last_hop["rtmin"]
    metrics["hop_%d_rtmax" % last_hop_num] = last_hop["rtmax"]
    metrics["hop_%d_rtstddev" % last_hop_num] = last_hop["rtstddev"]
    metrics["hop_%d_response_time" % last_hop_num] = last_hop["response_time"]
    metrics["hop_%d_pl" % last_hop_num] = last_hop["pl"]
    
    # Hops count metric
    metrics["hops"] = len(hops)
    
    details = "\n".join(details_parts) if details_parts else ""
    msg = ", ".join(msg_parts)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}