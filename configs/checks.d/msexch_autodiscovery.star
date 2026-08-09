def main(ctx, params):
    if params.get("_discover"):
        # Probe for WMI capability - this is a Windows WMI check
        # On a Linux host, WMI is not available, so this check does not apply
        res = ctx.run(["wmic", "os", "get", "Caption"], mutates=False)
        if res.rc == 127:
            # wmic not installed - not a Windows host with WMI
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        if res.rc != 0:
            # WMI present but error - treat as not applicable
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # wmic works - this is a Windows host, but Exchange Autodiscovery
        # WMI class is very specific; check for it
        exch = ctx.run(["wmic", "process", "where", "name='w3wp.exe'", "get", "processid"],
                       mutates=False)
        if exch.rc != 0 or not exch.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # Exchange Autodiscovery - single service check with item ""
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["requests_per_sec"]}
                ]}}
    
    # Check mode - query the WMI table for Exchange Autodiscovery RequestsPersec
    item = params.get("item", "")
    res = ctx.run(["wmic", "path", "Win32_PerfRawData_MSExchangeAutodiscover_Server",
                   "get", "Name,RequestsPersec"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "WMI not available (wmic not installed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "WMI query failed or Exchange Autodiscovery not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "no Exchange Autodiscovery data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Look for _Total row
    total_value = None
    for line in lines[1:]:
        parts = line.split()
        if len(parts) >= 2:
            name = parts[0]
            value_str = parts[1]
            if name in ["_Total", "__Total__", "_Global"]:
                total_value = value_str
                break
    
    if total_value == None:
        return {"changed": False, "msg": "no total instance found in Exchange Autodiscovery",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the value
    if not total_value.isdigit():
        return {"changed": False, "msg": "invalid RequestsPersec value: %s" % total_value,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    rate = int(total_value)
    
    # No thresholds defined in the check
    warn = params.get("warn", 0)
    crit = params.get("crit", 0)
    
    state = "OK"
    if crit > 0 and rate >= crit:
        state = "CRIT"
    elif warn > 0 and rate >= warn:
        state = "WARN"
    
    return {"changed": False,
            "msg": "Exchange Autodiscovery Requests/sec: %d" % rate,
            "data": {"state": state, "metrics": {"requests_per_sec": rate}, "details": ""}}