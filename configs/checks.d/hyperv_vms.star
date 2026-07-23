def main(ctx, params):
    # Discovery mode: enumerate all VMs and their current state
    if params.get("_discover"):
        # Try both default and tab-separated formats
        res = ctx.run(["Get-VM"], mutates=False)
        if res.rc != 0:
            # Fallback to raw text mode if Get-VM is not available
            res = ctx.run(["powershell", "-Command", "Get-VM"], mutates=False)
        
        vms = []
        if res.rc == 0:
            lines = res.stdout.splitlines()
            # Parse PowerShell Get-VM output: Name, State, Uptime, Status
            # Format: Name<tab>State<tab>Uptime<tab>Status
            for line in lines:
                parts = line.strip().split("\t")
                if len(parts) >= 2:
                    vm_name = parts[0]
                    state = parts[1]
                    # Skip header line if present
                    if vm_name == "Name" or state == "State":
                        continue
                    # Only include VMs with known states
                    if state in [
                        "FastSaved", "FastSavedCritical", "FastSaving", "FastSavingCritical",
                        "Off", "OffCritical", "Other", "Paused", "PausedCritical",
                        "Pausing", "PausingCritical", "Reset", "ResetCritical",
                        "Resuming", "ResumingCritical", "Running", "RunningCritical",
                        "Saved", "SavedCritical", "Saving", "SavingCritical",
                        "Starting", "StartingCritical", "Stopping", "StoppingCritical"
                    ]:
                        vms.append({
                            "item": vm_name,
                            "params": {"discovered_state": state},
                            "metrics": []
                        })
        
        return {
            "changed": False,
            "msg": "discovered %d VMs" % len(vms),
            "data": {"discovery": vms}
        }
    
    # Check mode for a specific VM
    item = params.get("item", "")
    res = ctx.run(["Get-VM"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["powershell", "-Command", "Get-VM"], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "no VM data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse the VM data
    lines = res.stdout.splitlines()
    vm_state = None
    vm_state_msg = ""
    for line in lines:
        parts = line.strip().split("\t")
        if len(parts) >= 4:
            name = parts[0]
            if name == item and name != "Name":
                vm_state = parts[1]
                vm_state_msg = parts[3] if len(parts) > 3 else "Operating normally"
                break
    
    if vm_state == None:
        return {
            "changed": False,
            "msg": "VM not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine service state based on mapping rules
    compare_mode = params.get("vm_target_state", ("map", {}))[0]
    
    # Default state mapping (from Checkmk source)
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
    
    # Determine target state
    if compare_mode == "discovery":
        discovered_state = params.get("discovered_state")
        if discovered_state == None:
            return {
                "changed": False,
                "msg": "State is %s (%s), discovery state is not available" % (vm_state, vm_state_msg),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        if vm_state == discovered_state:
            return {
                "changed": False,
                "msg": "State %s (%s) matches discovery" % (vm_state, vm_state_msg),
                "data": {"state": "OK", "metrics": {}, "details": ""}
            }
        else:
            return {
                "changed": False,
                "msg": "State %s (%s) does not match discovery (%s)" % (vm_state, vm_state_msg, discovered_state),
                "data": {"state": "CRIT", "metrics": {}, "details": ""}
            }
    
    # Service state defined in rule (map mode)
    target_states = DEFAULT_STATE_MAPPING
    extra_states = params.get("vm_target_state", ("map", {}))[1]
    if type(extra_states) == "dict":
        for k, v in extra_states.items():
            target_states[k] = v
    
    service_state = target_states.get(vm_state)
    
    if service_state == None:
        return {
            "changed": False,
            "msg": "Unknown state %s (%s)" % (vm_state, vm_state_msg),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Map Checkmk states to our state names
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    our_state = state_map.get(service_state, "UNKNOWN")
    
    return {
        "changed": False,
        "msg": "State is %s (%s)" % (vm_state, vm_state_msg),
        "data": {"state": our_state, "metrics": {}, "details": ""}
    }