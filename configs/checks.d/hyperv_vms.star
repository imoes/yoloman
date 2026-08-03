DEFAULT_STATE_MAPPING = {
    "FastSaved": 0,
    "FastSavedCritical": 2,
    "FastSaving": 0,
    "FastSavingCritical": 2,
    "Off": 1,
    "OffCritical": 2,
    "Other": 3,
    "Paused": 0,
    "PausedCritical": 2,
    "Pausing": 0,
    "PausingCritical": 2,
    "Reset": 1,
    "ResetCritical": 2,
    "Resuming": 0,
    "ResumingCritical": 2,
    "Running": 0,
    "RunningCritical": 2,
    "Saved": 0,
    "SavedCritical": 2,
    "Saving": 0,
    "SavingCritical": 2,
    "Starting": 0,
    "StartingCritical": 2,
    "Stopping": 1,
    "StoppingCritical": 2,
}

def _strip_quotes(s):
    s2 = s.strip()
    if len(s2) >= 2 and s2[0] == '"' and s2[-1] == '"':
        return s2[1:-1]
    return s2

def _parse_uptime_hex(uptime):
    parts = uptime.split(":")
    if len(parts) == 3:
        h_valid = parts[0].isdigit()
        m_valid = parts[1].isdigit()
        s_valid = parts[2].isdigit()
        if h_valid and m_valid and s_valid:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    return None

def _probe(ctx, params):
    # Detect whether this is a Windows host with the Hyper-V role / module.
    res = ctx.run(["powershell", "-NoProfile", "-Command",
        "Get-WindowsFeature -Name Hyper-V | Where-Object {$_.Installed}"], mutates=False)
    hv_installed = res.rc == 0 and res.stdout.find("Hyper-V") != -1
    if not hv_installed:
        res2 = ctx.run(["powershell", "-NoProfile", "-Command",
            "Get-Module -ListAvailable -Name Hyper-V"], mutates=False)
        if res2.rc != 0 or res2.stdout.find("Hyper-V") == -1 and res2.stdout.find("Microsoft.Windows.HyperV") == -1:
            return None
    # Enumerate VMs using live data
    res3 = ctx.run(["powershell", "-NoProfile", "-Command",
        "Get-VM | ForEach-Object { $_.Name + '|' + $_.State + '|' + $_.Uptime.ToString() + '|' + $_.Status }"],
        mutates=False)
    if res3.rc != 0:
        return {}
    vms = {}
    for line in res3.stdout.splitlines():
        fields = line.split("|")
        if len(fields) != 4:
            continue
        name = fields[0]
        state = fields[1]
        uptime = fields[2]
        status = fields[3]
        if uptime.find(":") == -1:
            continue
        vms[name] = {"state": state, "uptime": uptime, "state_msg": status}
    return vms

def main(ctx, params):
    if params.get("_discover"):
        vms = _probe(ctx, params)
        if vms == None:
            return {"changed": False, "msg": "no hyper-v module found",
                    "data": {"discovery": []}}
        out = []
        for name, vm in vms.items():
            out.append({"item": name,
                        "params": {"discovered_state": vm["state"]},
                        "metrics": ["uptime_seconds"]})
        return {"changed": False, "msg": "discovered %d VMs" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    vms = _probe(ctx, params)
    if vms == None:
        return {"changed": False, "msg": "no hyper-v module found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item not in vms:
        return {"changed": False, "msg": "no such VM: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vm = vms[item]
    target = params.get("vm_target_state", ("discovery", {}))
    compare_mode = target[0]
    if compare_mode == "discovery":
        discovered_state = params.get("discovered_state")
        if discovered_state == None:
            return {"changed": False,
                    "msg": "State is %s (%s), discovery state is not available" % (vm["state"], vm["state_msg"]),
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if vm["state"] == discovered_state:
            return {"changed": False,
                    "msg": "State %s (%s) matches discovery" % (vm["state"], vm["state_msg"]),
                    "data": {"state": "OK", "metrics": {}, "details": ""}}
        return {"changed": False,
                "msg": "State %s (%s) does not match discovery (%s)" % (vm["state"], vm["state_msg"], discovered_state),
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    mapping = DEFAULT_STATE_MAPPING
    custom = target[1] if len(target) > 1 else {}
    service_state = mapping.get(vm["state"])
    if service_state == None:
        service_state = custom.get(vm["state"])
    if service_state == None:
        return {"changed": False,
                "msg": "Unknown state %s (%s)" % (vm["state"], vm["state_msg"]),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    secs = _parse_uptime_hex(vm["uptime"])
    metrics = {}
    if secs != None:
        metrics["uptime_seconds"] = secs
    st = "OK"
    if service_state == 0:
        st = "OK"
    elif service_state == 1:
        st = "WARN"
    elif service_state == 2:
        st = "CRIT"
    elif service_state == 3:
        st = "UNKNOWN"
    return {"changed": False,
            "msg": "State is %s (%s)" % (vm["state"], vm["state_msg"]),
            "data": {"state": st, "metrics": metrics, "details": ""}}