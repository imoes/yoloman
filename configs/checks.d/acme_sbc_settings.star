def main(ctx, params):
    if params.get("_discover"):
        # Discovery: one single service with no item, parameters are the settings
        res = ctx.run(["show", "health"], mutates=False)
        # If the command fails or output is empty, return no items
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        settings = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) == 2:
                # Format: "<SettingName>    <Value>"
                key = parts[0]
                value = parts[1]
                if key and value:
                    settings[key] = value
        
        # Return one service with empty item and params as settings
        discovery = [{"item": "", "params": settings, "metrics": []}]
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": discovery}}
    
    # Check mode
    # params contains the expected settings (saved_settings)
    saved_settings = params
    
    res = ctx.run(["show", "health"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "Unable to retrieve health data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    current_settings = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) == 2:
            key = parts[0]
            value = parts[1]
            if key and value:
                current_settings[key] = value
    
    # Summary
    summary_lines = []
    summary_lines.append("Checking %d settings" % len(saved_settings))
    
    # Check each saved setting
    changed_settings = []
    for setting, expected_value in saved_settings.items():
        current_value = current_settings.get(setting, "")
        if current_value != expected_value:
            changed_settings.append("%s changed from %s to %s" % 
                                   (setting, expected_value, current_value))
    
    # Determine state
    state = "CRIT" if changed_settings else "OK"
    
    # Build details (empty for now, per Checkmk style)
    details = ""
    
    # Build final message
    msg = "; ".join(summary_lines)
    if changed_settings:
        msg += "; " + "; ".join(changed_settings)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": details}}
