def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["wmic", "path", "Win32_PerfRawData_MicrosoftExchangeAutodiscovery", "get", "RequestsPersec", "/value"], mutates=False)
        # Check if we got data (exit code 0 means WMI query succeeded)
        if res.rc == 0 and res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {},
                            "metrics": ["requests_per_sec"]
                        }
                    ]
                }
            }
        # Alternative approach: try the default Exchange WMI class
        res = ctx.run(["wmic", "path", "Win32_PerfRawData_MicrosoftExchangeAutodiscovery_Autodiscovery", "get", "RequestsPersec", "/value"], mutates=False)
        if res.rc == 0 and res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {},
                            "metrics": ["requests_per_sec"]
                        }
                    ]
                }
            }
        # Check for any Exchange Autodiscovery WMI class
        res = ctx.run(["wmic", "path", "Win32_PerfRawData", "get", "name", "/value"], mutates=False)
        if res.rc == 0 and "Autodiscovery" in res.stdout:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {},
                            "metrics": ["requests_per_sec"]
                        }
                    ]
                }
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }
    
    # Check mode
    # Try different possible WMI class names for Exchange Autodiscovery
    wmi_classes = [
        "Win32_PerfRawData_MicrosoftExchangeAutodiscovery",
        "Win32_PerfRawData_MicrosoftExchangeAutodiscovery_Autodiscovery"
    ]
    
    requests_per_sec = None
    
    for wmi_class in wmi_classes:
        res = ctx.run(["wmic", "path", wmi_class, "get", "RequestsPersec", "/value"], mutates=False)
        if res.rc == 0 and res.stdout.strip():
            # Parse the value from "RequestsPersec=<number>"
            for line in res.stdout.splitlines():
                line = line.strip()
                if line.startswith("RequestsPersec="):
                    val_str = line.split("=", 1)[1].strip()
                    if val_str.isdigit():
                        requests_per_sec = int(val_str)
                        break
        if requests_per_sec != None:
            break
    
    # If WMI query failed or no data, return UNKNOWN
    if requests_per_sec == None:
        return {
            "changed": False,
            "msg": "Exchange Autodiscovery data not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Return the metric value
    return {
        "changed": False,
        "msg": "Requests/sec: %d" % requests_per_sec,
        "data": {
            "state": "OK",
            "metrics": {"requests_per_sec": requests_per_sec},
            "details": ""
        }
    }
