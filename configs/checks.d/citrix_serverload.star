def main(ctx, params):
    # Discovery mode: yield single service (item "")
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"levels": [85.0, 95.0]}, "metrics": ["citrix_load"]}]}
        }

    # Check mode: fetch serverload data
    # The Checkmk agent section <<<citrix_serverload>>> is implemented by reading
    # /opt/citrix/ics/Config/ServerLoad.xml or via a local query; we replicate that
    # by reading the same XML file used by the Citrix agent plugin.
    load_file = "/opt/citrix/ics/Config/ServerLoad.xml"
    
    if not ctx.file_exists(load_file):
        return {
            "changed": False,
            "msg": "ServerLoad.xml not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    content = ctx.file_read(load_file)
    load_value = None
    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith("<ServerLoad>"):
            end_tag = stripped.find("</ServerLoad>")
            if end_tag > 0:
                inner = stripped[len("<ServerLoad>"):end_tag].strip()
                if inner.isdigit():
                    load_value = int(inner)
                break
            else:
                # Multi-line case — fall through to full parse
                pass
    
    # If not found by above simple scan, try to find in full content
    if load_value == None:
        # Instead, use manual string scan:
        start = content.find("<ServerLoad>")
        if start >= 0:
            start += len("<ServerLoad>")
            end = content.find("</ServerLoad>", start)
            if end >= 0:
                inner = content[start:end].strip()
                if inner.isdigit():
                    load_value = int(inner)
    
    if load_value == None:
        return {
            "changed": False,
            "msg": "could not parse ServerLoad value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Handle license error (20000) — set to 10000 for calculation
    if load_value == 20000:
        summary = "License error"
        load_pct = 10000 / 100.0
    else:
        summary = ""
        load_pct = load_value / 100.0

    # Thresholds from params
    levels = params.get("levels", [85.0, 95.0])
    warn = levels[0] if len(levels) >= 1 else 85.0
    crit = levels[1] if len(levels) >= 2 else 95.0

    # Determine state
    if load_pct >= crit:
        state = "CRIT"
    elif load_pct >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Build message
    if summary:
        msg = summary + ", Current Citrix Load: %f%%" % load_pct
    else:
        msg = "Current Citrix Load: %f%%" % load_pct

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"citrix_load": load_pct},
            "details": ""
        }
    }