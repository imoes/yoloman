def main(ctx, params):
    if params.get("_discover"):
        # Check for Skype for Business Server presence
        res = ctx.run(["which", "pwsh"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "Skype for Business Server not found", "data": {"discovery": []}}
        
        # Try to check for Lync/Skype for Business Server via PowerShell
        ps_res = ctx.run([
            "pwsh", "-Command",
            "Get-Service -Name 'RTCSrv' -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count"
        ], mutates=False)
        
        if ps_res.rc != 0 or ps_res.stdout.strip() == "0":
            return {"changed": False, "msg": "Skype for Business Server not found", "data": {"discovery": []}}
        
        # Check for required WMI tables
        wmi_res = ctx.run([
            "pwsh", "-Command",
            "Get-CimInstance -Query 'SELECT Name FROM Win32_PerfFormat_Category WHERE Name LIKE \"LS:WEB - UCWA%\"' | Measure-Object | Select-Object -ExpandProperty Count"
        ], mutates=False)
        
        if wmi_res.rc != 0 or wmi_res.stdout.strip() == "0":
            return {"changed": False, "msg": "Required WMI tables not found", "data": {"discovery": []}}
        
        # Discovery: service_name is "Skype Mobile Sessions" (single service)
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [{
                    "item": "",
                    "params": {
                        "requests_processing": {"upper": (10000, 20000)}
                    },
                    "metrics": [
                        "ucwa_active_sessions_android",
                        "ucwa_active_sessions_ipad",
                        "ucwa_active_sessions_iphone",
                        "ucwa_active_sessions_mac",
                        "web_requests_processing"
                    ]
                }]
            }
        }
    
    # Check mode - check one item
    item = params.get("item", "")
    
    # Verify Skype for Business Server is present
    res = ctx.run(["which", "pwsh"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "Skype for Business Server (pwsh) not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Gather UCWA active sessions by platform
    metrics = {}
    details = []
    worst_state = "OK"
    
    # Check defaults from plugin
    requests_processing_levels = params.get("requests_processing", {"upper": (10000, 20000)})
    rp_warn, rp_crit = requests_processing_levels.get("upper", (10000, 20000))
    
    # Query WMI for UCWA table
    ucwa_res = ctx.run([
        "pwsh", "-Command",
        "Get-CimInstance -Namespace root\\StandardCimv2 -Query 'SELECT * FROM Win32_PerfFormattedData_PerfProc_UCWA' 2>$null; "
        # Actually, the WMI class names vary. Let me use the performance counter approach.
    ], mutates=False)
    
    # This is getting complex. The original check reads from Checkmk's WMI agent section.
    # The WMI data comes from specific performance counter classes.
    
    # For the UCWA table, the instances are AndroidLync, iPadLync, iPhoneLync, LyncForMac
    # and the column is "UCWA - Active Session Count"
    # For Throttling table, the column is "WEB - Total Requests In Processing"
    
    # Let me query the WMI performance counters directly
    query = """
    $ucwa = Get-CimInstance -Query "
        SELECT Name, `"`UCWA - Active Session Count`" AS ActiveSessions 
        FROM Win32_PerfFormattedData_PerfProc_UCWA
    " -ErrorAction SilentlyContinue
    
    $throttle = Get-CimInstance -Query "
        SELECT `"`WEB - Total Requests In Processing`" AS Requests
        FROM Win32_PerfFormattedData_PerfProc_ThrottlingAndAuth
    " -ErrorAction SilentlyContinue
    
    $result = @{
        ucwa = $ucwa | Select-Object Name, ActiveSessions
        throttle = $throttle | Select-Object Requests
    }
    $result | ConvertTo-Json -Depth 3
    """
    
    wmi_res = ctx.run(["pwsh", "-NoProfile", "-Command", query], mutates=False)
    
    if wmi_res.rc != 0:
        return {"changed": False, "msg": "Failed to query WMI for Skype data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": wmi_res.stderr}}
    
    # Parse the JSON output
    if not wmi_res.stdout or wmi_res.stdout.strip() == "":
        return {"changed": False, "msg": "No Skype WMI data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(wmi_res.stdout)
    
    # Process UCWA active sessions
    platform_map = [
        ("AndroidLync", "android"),
        ("iPadLync", "ipad"),
        ("iPhoneLync", "iphone"),
        ("LyncForMac", "mac"),
    ]
    
    for instance_name, platform_key in platform_map:
        value = None
        if data.get("ucwa"):
            for entry in data["ucwa"]:
                if entry.get("Name") == instance_name:
                    value = entry.get("ActiveSessions")
                    break
        
        if value != None:
            v = int(value) if value != "" else 0
            metrics["ucwa_active_sessions_" + platform_key] = v
            details.append("%s: %d active sessions" % (platform_key, v))
    
    # Process web requests processing
    rp_value = None
    if data.get("throttle"):
        rp_value = data["throttle"].get("Requests")
    
    if rp_value != None and rp_value != "":
        rp = int(rp_value)
        metrics["web_requests_processing"] = rp
        details.append("Web requests in processing: %d" % rp)
        
        if rp >= rp_crit:
            worst_state = "CRIT"
        elif rp >= rp_warn:
            worst_state = "WARN" if worst_state == "OK" else worst_state
    
    if len(metrics) == 0:
        return {"changed": False, "msg": "No Skype data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    summary = ", ".join(details) if details else "No data"
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": worst_state,
            "metrics": metrics,
            "details": "\n".join(details)
        }
    }