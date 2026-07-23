# Hyper-V integration service name mapping (Windows service name → display name)
VMIC_DISPLAY_NAMES = {
    "vmicheartbeat": "Heartbeat",
    "vmictimesync": "Time Synchronization",
    "vmicvss": "VSS (Volume Shadow Copy Service)",
    "vmickvpexchange": "Key-Value Pair Exchange",
    "vmicshutdown": "Shutdown",
    "vmicguestinterface": "Guest Service Interface",
    "vmicrdv": "Remote Desktop Virtualization",
    "vmicvmsession": "PowerShell Direct",
}

# Per-service overrides matching Checkmk's check_default_parameters
DEFAULT_MATCH_SERVICES = {
    "Guest Service Interface": {
        "default_status": "inactive",
        "state_if_not_default": 0,
    },
}

def _state_name(code):
    if code == 0:
        return "OK"
    if code == 1:
        return "WARN"
    if code == 2:
        return "CRIT"
    return "UNKNOWN"

def _query_services(ctx):
    facts = ctx.facts()
    if facts.get("os_family", "").lower() != "windows":
        return {}
    res = ctx.run(
        ["powershell.exe", "-NonInteractive", "-Command",
         "Get-Service vmic* | ForEach-Object { $_.Name + ':' + $_.Status }"],
        mutates=False,
        ok_codes=[0, 1],
    )
    if res.rc != 0 or not res.stdout.strip():
        return {}
    services = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if ":" not in line:
            continue
        parts = line.split(":", 1)
        name = parts[0].lower()
        status = parts[1].lower()
        display = VMIC_DISPLAY_NAMES.get(name, name)
        services[display] = "active" if status == "running" else "inactive"
    return services

def main(ctx, params):
    if params.get("_discover"):
        services = _query_services(ctx)
        if len(services) == 0:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{
                "item": "",
                "params": {
                    "default_status": "active",
                    "state_if_not_default": 1,
                    "match_services": [],
                },
                "metrics": [],
            }]},
        }

    global_default_status = params.get("default_status", "active")
    global_state_if_not_default = params.get("state_if_not_default", 1)

    # Build per-service override map: Checkmk defaults, then user params on top
    match_services = {}
    for svc_name, settings in DEFAULT_MATCH_SERVICES.items():
        match_services[svc_name] = settings

    param_match = params.get("match_services", [])
    if type(param_match) == "list":
        for svc_cfg in param_match:
            if type(svc_cfg) == "dict":
                svc_name = svc_cfg.get("service_name", "")
                if svc_name:
                    match_services[svc_name] = {
                        "default_status": svc_cfg.get("default_status", "active"),
                        "state_if_not_default": svc_cfg.get("state_if_not_default", 1),
                    }

    services = _query_services(ctx)
    if len(services) == 0:
        return {
            "changed": False,
            "msg": "no Hyper-V integration services found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    summaries = []
    worst = 0

    for svc_display, svc_status in services.items():
        if svc_display in match_services:
            svc_settings = match_services[svc_display]
            expected = svc_settings["default_status"]
            sif = svc_settings["state_if_not_default"]
        else:
            expected = global_default_status
            sif = global_state_if_not_default

        if svc_status == expected:
            code = 0
        elif svc_status == "active" or svc_status == "inactive":
            code = sif
        else:
            code = 3

        if code > worst:
            worst = code
        summaries.append("%s: %s" % (svc_display, svc_status))

    return {
        "changed": False,
        "msg": ", ".join(summaries),
        "data": {
            "state": _state_name(worst),
            "metrics": {},
            "details": "",
        },
    }