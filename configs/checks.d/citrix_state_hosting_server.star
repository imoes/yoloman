def main(ctx, params):
    if params.get("_discover"):
        # Discover hosting server service
        return {
            "changed": False,
            "msg": "discovered 1 hosting server service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: read the citrix state data via agent
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/citrix_state"], mutates=False)
    if res.rc != 0:
        # Agent data unavailable -> UNKNOWN
        return {
            "changed": False,
            "msg": "Citrix state data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse agent output manually (no Checkmk agent required)
    section = {"instance": {}, "controller": "", "hosting_server": ""}
    for line in res.stdout.splitlines():
        if not line:
            continue
        fields = line.split(None, 1)
        if len(fields) < 2:
            continue
        key = fields[0]
        value = fields[1] if len(fields) > 1 else ""
        if key == "Controller":
            section["controller"] = value
        elif key == "HostingServer":
            section["hosting_server"] = value
        elif key in [
            "FaultState",
            "MaintenanceMode",
            "PowerState",
            "RegistrationState",
            "VMToolsState",
            "AgentVersion",
            "Catalog",
            "DesktopGroupName",
        ]:
            section["instance"][key] = value

    # Check hosting server state
    summary = section.get("hosting_server", "")
    if summary == "":
        summary = "Machine powered off"

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }
