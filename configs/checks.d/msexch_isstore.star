def main(ctx, params):
    if params.get("_discover"):
        ps_cmd = "Get-WmiObject -Class Win32_PerfRawData_MSExchangeIS_MSExchangeISStore | Select-Object Name,RPCAverageLatency,RPCAverageLatency_Base"
        res = ctx.run(["powershell.exe", "-NoProfile", "-Command", ps_cmd], mutates=False)
        if res.rc != 0:
            ps_cmd_alt = "Get-WmiObject -Class Win32_PerfRawData_MSSQLSERVER_MSExchangeISStore | Select-Object Name,RPCAverageLatency,RPCAverageLatency_Base"
            res = ctx.run(["powershell.exe", "-NoProfile", "-Command", ps_cmd_alt], mutates=False)

        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        items = []
        for line in lines:
            fields = line.strip().split()
            if len(fields) >= 1:
                name = fields[0].strip()
                if name and name.lower() != "":
                    items.append({"item": name, "params": {}, "metrics": ["average_latency_s"]})

        return {"changed": False, "msg": "discovered %d items" % len(items), "data": {"discovery": items}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ps_cmd = "Get-WmiObject -Class Win32_PerfRawData_MSExchangeIS_MSExchangeISStore | Where-Object { $_.Name -eq '%s' } | Select-Object Name,RPCAverageLatency,RPCAverageLatency_Base" % item
    res = ctx.run(["powershell.exe", "-NoProfile", "-Command", ps_cmd], mutates=False)
    if res.rc != 0:
        ps_cmd_alt = "Get-WmiObject -Class Win32_PerfRawData_MSSQLSERVER_MSExchangeISStore | Where-Object { $_.Name -eq '%s' } | Select-Object Name,RPCAverageLatency,RPCAverageLatency_Base" % item
        res = ctx.run(["powershell.exe", "-NoProfile", "-Command", ps_cmd_alt], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "failed to query WMI for item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return {"changed": False, "msg": "no data for item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data_line = lines[0].strip()
    fields = data_line.split()
    if len(fields) < 3:
        return {"changed": False, "msg": "incomplete data for item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rpc_lat_str = fields[1]
    rpc_lat_base_str = fields[2]

    if not rpc_lat_str.isdigit():
        return {"changed": False, "msg": "invalid latency value for item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    rpc_lat = int(rpc_lat_str)

    if not rpc_lat_base_str.isdigit():
        return {"changed": False, "msg": "invalid base value for item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    rpc_lat_base = int(rpc_lat_base_str)

    if rpc_lat_base < 0:
        rpc_lat_base = rpc_lat_base + (1 << 32)

    latency_s = 0.0
    if rpc_lat_base != 0:
        latency_s = float(rpc_lat) / float(rpc_lat_base)

    warn_val = params.get("store_latency_s")
    crit_val = params.get("store_latency_s")

    if type(warn_val) == "list":
        warn = warn_val[1] if len(warn_val) > 1 else 0.04
    else:
        warn = 0.04

    if type(crit_val) == "list":
        crit = crit_val[1] if len(crit_val) > 1 else 0.05
    else:
        crit = 0.05

    state = "OK"
    if latency_s >= crit:
        state = "CRIT"
    elif latency_s >= warn:
        state = "WARN"

    latency_ms = latency_s * 1000.0
    msg = "%s %f ms latency" % (item, latency_ms)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"average_latency_s": latency_s},
            "details": ""
        }
    }