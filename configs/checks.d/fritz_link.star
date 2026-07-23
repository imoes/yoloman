def main(ctx, params):
    _LINK_CHECK_FIELDS = [
        ("NewLinkStatus", "Link status"),
        ("NewPhysicalLinkStatus", "Physical link status"),
    ]
    
    # Get the fritz agent section data
    res = ctx.run(["cat", "/var/lib/cmk/fritz"], mutates=False)
    
    # Parse the agent section: key-value pairs
    section = {}
    for line in res.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) >= 2:
            section[parts[0]] = parts[1]
    
    # Check if required fields are present for discovery
    if params.get("_discover"):
        if "NewLinkStatus" in section and "NewPhysicalLinkStatus" in section:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {"changed": False, "msg": "discovered 0 services", "data": {"discovery": []}}
    
    # Check mode: monitor link status
    details = []
    state = "OK"
    
    for key, label in _LINK_CHECK_FIELDS:
        value = section.get(key)
        if value != None:
            current_state = "OK" if value == "Up" else "CRIT"
            if current_state != "OK":
                state = current_state
            details.append("%s: %s" % (label, value))
    
    if not details:
        return {
            "changed": False,
            "msg": "no link status data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    return {
        "changed": False,
        "msg": ", ".join(details),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
