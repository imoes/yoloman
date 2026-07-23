def main(ctx, params):
    # State names mapping: code -> name
    STATE_NAMES = {
        1: "Uninitialized",
        2: "Initialized",
        3: "Running",
        4: "Disabling",
        5: "Disabled",
        6: "ShutdownPending",
        7: "DeletePending",
    }
    
    # Default state mapping: name -> Checkmk State enum value
    STATE_MAP_DEFAULT = {
        "Uninitialized": 2,
        "Initialized": 1,
        "Running": 0,
        "Disabling": 2,
        "Disabled": 2,
        "ShutdownPending": 2,
        "DeletePending": 2,
    }
    
    # DISCOVERY MODE
    if params.get("_discover"):
        # Try PowerShell approach first
        res = ctx.run(["powershell", "-Command", "(Get-IISSite | ForEach-Object { $_.Applications } | ForEach-Object { $_.ApplicationPools } | Select-Object -Unique Name) | ForEach-Object { $pool = $_; $state = (Get-ItemProperty -Path \"IIS:\\AppPools\\$pool\" -Name State -ErrorAction SilentlyContinue).Value; if ($state -ne $null) { Write-Output \"$pool $state\" } }"], mutates=False)
        
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "discovered 0 application pools (data unavailable)",
                "data": {"discovery": []}
            }
        
        section = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2:
                app = parts[0].strip()
                state_code = parts[1].strip()
                if state_code.isdigit():
                    section[app] = int(state_code)
        
        discoveries = []
        for app in section:
            discoveries.append({
                "item": app,
                "params": {"state_mapping": STATE_MAP_DEFAULT},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d application pools" % len(discoveries),
            "data": {"discovery": discoveries}
        }
    
    # CHECK MODE
    item = params.get("item", "")
    state_mapping = params.get("state_mapping", STATE_MAP_DEFAULT)
    
    # Gather data - use same logic as discovery
    res = ctx.run(["powershell", "-Command", "(Get-IISSite | ForEach-Object { $_.Applications } | ForEach-Object { $_.ApplicationPools } | Select-Object -Unique Name) | ForEach-Object { $pool = $_; $state = (Get-ItemProperty -Path \"IIS:\\AppPools\\$pool\" -Name State -ErrorAction SilentlyContinue).Value; if ($state -ne $null) { Write-Output \"$pool $state\" } }"], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "%s is unknown" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    section = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            app = parts[0].strip()
            state_code = parts[1].strip()
            if state_code.isdigit():
                section[app] = int(state_code)
    
    # Check the specific item
    state_code = section.get(item)
    if state_code == None:
        return {
            "changed": False,
            "msg": "%s is unknown" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state_name = STATE_NAMES.get(state_code, "Unknown")
    state_value = state_mapping.get(state_name, 2)
    
    state_str = "OK" if state_value == 0 else ("WARN" if state_value == 1 else "CRIT")
    
    return {
        "changed": False,
        "msg": "State: %s" % state_name,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }