# Default parameters mirroring Checkmk defaults
DEFAULT_PARAMS = {
    "power_state": {
        "running": 0,
        "off": 2,
        "saved": 0,
        "paused": 1,
        "starting": 1,
    },
    "vm_generation": {
        "expected_generation": "generation_2",
        "state_if_not_expected": 1,
    },
}

# Hyper-V power state names to numeric State values (OK/WARN/CRIT/UNKNOWN)
STATE_OK = 0
STATE_WARN = 1
STATE_CRIT = 2
STATE_UNKNOWN = 3

def _get_power_state_value(power_state, params):
    power_mapping = params.get("power_state", DEFAULT_PARAMS["power_state"])
    default_mapping = DEFAULT_PARAMS["power_state"]
    lower_state = power_state.lower() if power_state else ""
    return power_mapping.get(lower_state, default_mapping.get(lower_state, STATE_UNKNOWN))

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # On non-Windows: cannot get Hyper-V data -> no discovery
        facts = ctx.facts()
        os_family = facts.get("os_family", "")
        if os_family != "windows":
            return {"changed": False, "msg": "discovered 0 items (non-Windows host)", 
                    "data": {"discovery": []}}
        
        # Run PowerShell to get VM data in JSON format
        res = ctx.run([
            "powershell", "-Command", 
            "Get-VM | Select-Object Name, Runtime.PowerState, Runtime.Host, Config.Generation | ConvertTo-Json -Compress"
        ], mutates=False)
        
        # Guard: check result code and output
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items (no VM data)", 
                    "data": {"discovery": []}}
        
        # Guard: parse JSON only if output looks like JSON
        json_output = res.stdout.strip()
        if not json_output or (json_output[0] != "{" and json_output[0] != "["):
            return {"changed": False, "msg": "discovered 0 items (malformed data)", 
                    "data": {"discovery": []}}
        
        vms = json.decode(json_output)
        
        # Ensure vms is a list (Get-VM returns array, but ConvertTo-Json may return dict if single VM)
        if type(vms) == "dict":
            vms = [vms]
        
        items = []
        for vm in vms:
            name = vm.get("Name", "")
            if name:
                items.append({"item": "", "params": DEFAULT_PARAMS, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d VM(s)" % len(items),
                "data": {"discovery": items}}
    
    # Check mode (single item)
    # On Windows, run PowerShell again to fetch VM data
    facts = ctx.facts()
    os_family = facts.get("os_family", "")
    if os_family != "windows":
        return {"changed": False, "msg": "Host is not Windows", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run([
        "powershell", "-Command",
        "Get-VM | Select-Object Name, Runtime.PowerState, Runtime.Host, Config.Generation | ConvertTo-Json -Compress"
    ], mutates=False)
    
    # Guard: check result code and output
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "Unable to retrieve VM data", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Guard: parse JSON only if output looks like JSON
    json_output = res.stdout.strip()
    if not json_output or (json_output[0] != "{" and json_output[0] != "["):
        return {"changed": False, "msg": "Unable to parse VM data", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    vms = json.decode(json_output)
    
    if type(vms) == "dict":
        vms = [vms]
    
    if not vms:
        return {"changed": False, "msg": "No Hyper-V VMs found", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # We're only checking the first VM (Checkmk discovery yields one service per host, not per VM)
    vm = vms[0]
    
    # Parse parameters
    power_params = params.get("power_state", DEFAULT_PARAMS["power_state"])
    vm_gen_params = params.get("vm_generation", DEFAULT_PARAMS["vm_generation"])
    
    name = vm.get("Name", "")
    
    # Handle nested JSON structure for Runtime and Config
    runtime = vm.get("Runtime")
    if type(runtime) == "dict":
        power_state = runtime.get("PowerState", "")
        host = runtime.get("Host", "")
    else:
        power_state = vm.get("Runtime.PowerState", "")
        host = vm.get("Runtime.Host", "")
    
    config = vm.get("Config")
    if type(config) == "dict":
        generation = config.get("Generation", "")
    else:
        generation = vm.get("Config.Generation", "")
    
    details_parts = []
    state = STATE_OK
    
    # VM name
    if not name:
        details_parts.append("VM name information is missing")
        state = STATE_WARN
    else:
        details_parts.append("VM name: " + name)
    
    # Power state
    if not power_state:
        details_parts.append("State information is missing")
        if state == STATE_OK:
            state = STATE_WARN
    else:
        ps_value = _get_power_state_value(power_state, params)
        details_parts.append("State: " + power_state)
        if ps_value > state:
            state = ps_value
    
    # Host
    if not host:
        details_parts.append("Host information is missing")
        if state == STATE_OK:
            state = STATE_WARN
    else:
        details_parts.append("Host: " + host)
    
    # VM generation
    if not generation:
        details_parts.append("VM Generation information is missing")
        if state == STATE_OK:
            state = STATE_WARN
    else:
        expected_generation = str(vm_gen_params.get("expected_generation", "generation_2"))
        expected_gen_number = expected_generation.replace("generation_", "")
        if generation != expected_gen_number:
            gen_state = int(vm_gen_params.get("state_if_not_expected", STATE_WARN))
            details_parts.append("VM Generation: " + generation + " (expected " + expected_generation + ")")
            if gen_state > state:
                state = gen_state
        else:
            details_parts.append("VM Generation: " + generation)
    
    summary = "; ".join(details_parts)
    return {"changed": False, "msg": summary,
            "data": {"state": "OK" if state == STATE_OK else ("WARN" if state == STATE_WARN else ("CRIT" if state == STATE_CRIT else "UNKNOWN")), 
                     "metrics": {}, "details": ""}}