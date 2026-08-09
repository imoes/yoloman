def main(ctx, params):
    # Discovery mode: disabled (never_discover), so return empty
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item is required for check mode",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather bonding info via netsh command for Windows
    res = ctx.run(["cmd", "/c", "netsh", "interface", "show", "interface"], mutates=False)
    lines = res.stdout.splitlines()
    
    # Find the bonding interface (Intel bonding appears as "Intel(R) Ethernet Converged")
    bond_info = None
    for line in lines:
        if item.lower() in line.lower():
            parts = line.strip().split()
            if len(parts) >= 2:
                status = "up" if parts[-1].lower() == "up" else ("down" if parts[-1].lower() == "down" else "degraded")
                bond_info = {
                    "status": status,
                    "mode": "fault-tolerance",
                    "interfaces": {},
                    "primary": "",
                    "active": "",
                }
                break

    # Since Windows Intel bonding doesn't expose structured agent data like Linux bonding,
    # and discovery is disabled, we must return UNKNOWN if no data is found
    if bond_info == None:
        return {"changed": False, "msg": "bonding interface not found or not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply check logic similar to Checkmk bonding plugin
    status = bond_info["status"]
    state = "OK" if status == "up" else ("WARN" if status == "degraded" else "CRIT")
    msg_parts = ["Status: " + status]

    mode = bond_info["mode"]
    msg_parts.append("Mode: " + mode)

    # Check primary/active interface
    primary = bond_info.get("primary", "")
    active = bond_info.get("active", "")
    if primary != "":
        msg_parts.append("Primary: " + primary)
    elif active != "":
        msg_parts.append("Active: " + active)

    # Check interfaces status (if available)
    if len(bond_info["interfaces"]) > 0:
        for iface in bond_info["interfaces"]:
            info = bond_info["interfaces"][iface]
            iface_status = info.get("status", "unknown")
            hwaddr = info.get("hwaddr", "")
            if hwaddr != "":
                summary = iface + "/" + hwaddr + " " + iface_status
            else:
                summary = iface + " " + iface_status
            if iface_status == "up":
                state = "OK" if state == "OK" else state
            else:
                state = "WARN" if state == "OK" else state

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }