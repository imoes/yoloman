def main(ctx, params):
    # discovery mode: enumerate items (check names) from agent output
    if params.get("_discover"):
        res = ctx.run(["powershell", "-Command", "Get-MailboxDatabaseCopyStatus | Select-Object -ExpandProperty Check"], mutates=False)
        # Fallback if Get-MailboxDatabaseCopyStatus is not available: use raw agent section
        if res.rc != 0:
            # Try alternative command (Exchange Management Shell style)
            res = ctx.run(["powershell", "-Command", "& 'Get-MailboxDatabaseCopyStatus' | ForEach-Object { $_.Check }"], mutates=False)
            if res.rc != 0:
                # Last resort: parse via Get-DatabaseAvailabilityGroup
                res = ctx.run(["powershell", "-Command", "& 'Get-DatabaseAvailabilityGroup' | ForEach-Object { $_.Name + ':ClusterService'; $_.Name + ':ReplayService' }"], mutates=False)
                if res.rc != 0:
                    # Return empty discovery if no Exchange PowerShell cmdlets available
                    return {"changed": False, "msg": "discovered 0 items",
                            "data": {"discovery": []}}
        
        # Extract unique check names
        checks = set()
        for line in res.stdout.splitlines():
            s = line.strip()
            if s:
                checks.add(s)
        
        items = []
        for check in sorted(checks):
            items.append({"item": check, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d checks" % len(items),
                "data": {"discovery": items}}

    # check mode: verify one item (check name)
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no check item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Try primary command: Get-MailboxDatabaseCopyStatus (most direct)
    res = ctx.run(["powershell", "-Command", "& { $status = Get-MailboxDatabaseCopyStatus -Identity '%s' 2>&1; if ($status) { $status.Check } else { '' } }" % item], mutates=False)
    
    # Fallback: simpler query
    if res.rc != 0 or not res.stdout.strip():
        res = ctx.run(["powershell", "-Command", "& 'Get-MailboxDatabaseCopyStatus' | Where-Object { $_.Check -eq '%s' } | Select-Object -ExpandProperty Result" % item], mutates=False)
    
    # If still no result, try alternate method: get all results and filter
    if res.rc != 0 or not res.stdout.strip():
        res = ctx.run(["powershell", "-Command", "& 'Get-MailboxDatabaseCopyStatus' | Select-Object Check,Result"], mutates=False)
    
    # Parse output - look for matching check and its Result
    state = "UNKNOWN"
    summary = "check result not found"
    
    lines = res.stdout.splitlines() if res.stdout else []
    getit = False
    for i in range(len(lines)):
        line = lines[i].strip()
        if not line:
            continue
        
        # Try parsing key:value format
        if ":" in line:
            parts = line.split(":", 1)
            if len(parts) == 2:
                key = parts[0].strip()
                val = parts[1].strip()
                
                if key == "Check" and val == item:
                    getit = True
                elif key == "Result" and getit:
                    if val == "Passed" or val.endswith("fung bestanden"):
                        state = "OK"
                        summary = "Test Passed"
                    else:
                        state = "WARN"
                        summary = val
                    break
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }