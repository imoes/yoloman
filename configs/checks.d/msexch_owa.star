def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _exchange_owa_exists(ctx):
    res = ctx.run(["powershell", "-NoProfile", "-Command",
                   "Get-OwaVirtualDirectory -ErrorAction SilentlyContinue"],
                  mutates=False)
    return res.rc == 0


def _get_wmi_table(ctx, wmi_class, prop):
    cmd = "Import-Module NetAdapter; $o = Get-WmiObject -Class '" + wmi_class + "' -ErrorAction SilentlyContinue; if ($o) { $o | Select-Object -ExpandProperty '" + prop + "' }"
    res = ctx.run(["powershell", "-NoProfile", "-Command", cmd],
                  mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return None
    return res.stdout.strip()


def _get_owa_values(ctx):
    if not _exchange_owa_exists(ctx):
        return None
    requests = _get_wmi_table(ctx, "Win32_PerfRawData_MSExchangeOWA_OWA", "RequestsPersec")
    users = _get_wmi_table(ctx, "Win32_PerfRawData_MSExchangeOWA_OWA", "CurrentUniqueUsers")
    return {"RequestsPersec": requests, "CurrentUniqueUsers": users}


def _parse_int(val):
    if val == None:
        return None
    if val.isdigit():
        return int(val)
    return None


def _discover(ctx, params):
    if not _exchange_owa_exists(ctx):
        return {"changed": False, "msg": "no Exchange OWA found",
                "data": {"discovery": []}}
    return {"changed": False, "msg": "discovered Exchange OWA service",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["requests_per_sec", "current_users"]}
            ]}}


def _check(ctx, params):
    data = _get_owa_values(ctx)
    if data == None:
        return {"changed": False, "msg": "no Exchange OWA found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    metrics = {}
    details_parts = []
    rp = _parse_int(data.get("RequestsPersec"))
    if rp != None:
        metrics["requests_per_sec"] = rp
        details_parts.append("Requests/sec: %d" % rp)
    cu = _parse_int(data.get("CurrentUniqueUsers"))
    if cu != None:
        metrics["current_users"] = cu
        details_parts.append("Unique users: %d" % cu)
    if len(metrics) == 0:
        return {"changed": False, "msg": "no OWA values retrieved",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    msg = ", ".join(details_parts)
    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": metrics, "details": msg}}