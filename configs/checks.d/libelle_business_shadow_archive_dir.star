def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/libelle_business_shadow"], mutates=False)
        lines = res.stdout.splitlines()
        parsed = {}
        for line in lines:
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "Host:":
                parsed["host"] = parts[1]
            elif len(parts) >= 3 and parts[0] == "Start-Time:":
                parsed["start_time"] = parts[1] + ":" + parts[2]
            elif len(parts) >= 2 and parts[0] == "Release:":
                parsed["release"] = parts[1]
            elif len(parts) >= 2 and parts[0] == "Status:":
                parsed["status"] = parts[1]
            elif len(parts) >= 4 and (parts[0].startswith("trdrecover:") or parts[0].startswith("trdarchiver:")):
                parsed["process"] = parts[0].rstrip(":")
                parsed["process_status"] = parts[3]
            elif len(parts) >= 4 and parts[0] == "Archive-Dir" and parts[1] == "total:":
                parsed["arch_total_mb"] = _to_mb(parts[2])
            elif len(parts) >= 4 and parts[0] == "Archive-Dir" and parts[1] == "free:":
                parsed["arch_free_mb"] = _to_mb(parts[2])
        
        discovery_items = []
        if "host" in parsed:
            discovery_items.append({"item": "Info", "params": {}, "metrics": []})
        if "status" in parsed:
            discovery_items.append({"item": "Status", "params": {}, "metrics": []})
        if "process" in parsed:
            discovery_items.append({"item": "Process", "params": {}, "metrics": []})
        if "arch_total_mb" in parsed and "arch_free_mb" in parsed:
            discovery_items.append({
                "item": "Archive Dir",
                "params": {"levels": (80, 90)},
                "metrics": ["used_percent"]
            })
        return {"changed": False, "msg": "discovered %d services" % len(discovery_items),
                "data": {"discovery": discovery_items}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/libelle_business_shadow"], mutates=False)
    lines = res.stdout.splitlines()
    parsed = {}
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "Host:":
            parsed["host"] = parts[1]
        elif len(parts) >= 3 and parts[0] == "Start-Time:":
            parsed["start_time"] = parts[1] + ":" + parts[2]
        elif len(parts) >= 2 and parts[0] == "Release:":
            parsed["release"] = parts[1]
        elif len(parts) >= 2 and parts[0] == "Status:":
            parsed["status"] = parts[1]
        elif len(parts) >= 4 and (parts[0].startswith("trdrecover:") or parts[0].startswith("trdarchiver:")):
            parsed["process"] = parts[0].rstrip(":")
            parsed["process_status"] = parts[3]
        elif len(parts) >= 4 and parts[0] == "Archive-Dir" and parts[1] == "total:":
            parsed["arch_total_mb"] = _to_mb(parts[2])
        elif len(parts) >= 4 and parts[0] == "Archive-Dir" and parts[1] == "free:":
            parsed["arch_free_mb"] = _to_mb(parts[2])

    if item == "Info":
        if not parsed:
            return {"changed": False, "msg": "no information found",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        msg = "Libelle Business Shadow"
        if "host" in parsed:
            msg += ", Host: " + parsed["host"]
        if "release" in parsed:
            msg += ", Release: " + parsed["release"]
        if "start_time" in parsed:
            msg += ", Start Time: " + parsed["start_time"]
        return {"changed": False, "msg": msg,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    elif item == "Status":
        if "status" not in parsed:
            return {"changed": False, "msg": "No information about libelle status found",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        state = "OK" if parsed["status"] == "RUN" else "CRIT"
        return {"changed": False, "msg": "Status is: " + parsed["status"],
                "data": {"state": state, "metrics": {}, "details": ""}}

    elif item == "Process":
        if "process" not in parsed:
            return {"changed": False, "msg": "No Active Process found",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        state = "OK" if parsed["process_status"] == "RUN" else "CRIT"
        return {"changed": False, "msg": "Active Process is: " + parsed["process"] + ", Status: " + parsed["process_status"],
                "data": {"state": state, "metrics": {}, "details": ""}}

    elif item == "Archive Dir":
        if "arch_total_mb" not in parsed or "arch_free_mb" not in parsed:
            return {"changed": False, "msg": "Archive directory information missing",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        total_mb = parsed["arch_total_mb"]
        free_mb = parsed["arch_free_mb"]
        used_mb = total_mb - free_mb
        
        # Calculate percentages (avoid division by zero)
        if total_mb == 0:
            used_percent = 0.0
        else:
            used_percent = float(used_mb * 100) / float(total_mb)
        
        warn = params.get("levels", (80, 90))[0]
        crit = params.get("levels", (80, 90))[1]
        
        # Check thresholds
        if used_percent >= crit:
            state = "CRIT"
        elif used_percent >= warn:
            state = "WARN"
        else:
            state = "OK"
        
        return {"changed": False, "msg": "Size: %f MB, Free: %f MB, Used: %f%%" % (float(used_mb), float(free_mb), used_percent),
                "data": {"state": state, "metrics": {"used_percent": used_percent, "size": total_mb, "free": free_mb}, "details": ""}}

    # Unknown item
    return {"changed": False, "msg": "Unknown service item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}


def _to_mb(size_str):
    # Convert size string like "150GB" to MB (int)
    if size_str.endswith("MB"):
        return int(float(size_str.replace("MB", "")))
    if size_str.endswith("GB"):
        return int(float(size_str.replace("GB", ""))) * 1024
    if size_str.endswith("TB"):
        return int(float(size_str.replace("TB", ""))) * 1024 * 1024
    if size_str.endswith("PB"):
        return int(float(size_str.replace("PB", ""))) * 1024 * 1024 * 1024
    if size_str.endswith("EB"):
        return int(float(size_str.replace("EB", ""))) * 1024 * 1024 * 1024 * 1024
    # Assume MB if no suffix
    return int(float(size_str))