_PS_CMD = "Get-WmiObject -Class Win32_PerfFormattedData_MSExchangeActiveSync_MSExchangeActiveSync -ErrorAction SilentlyContinue | Select-Object Name,RequestsPersec | ConvertTo-Json -Compress"

_PS_ARGV = ["powershell", "-NoProfile", "-NonInteractive", "-Command", _PS_CMD]

def _parse_wmi(stdout):
    out = stdout.strip()
    if not out or out == "null":
        return []
    data = json.decode(out)
    if type(data) == "dict":
        return [data]
    if type(data) == "list":
        return data
    return []

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(_PS_ARGV, mutates=False, ok_codes=[0, 1])
        instances = _parse_wmi(res.stdout)
        if not instances:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["requests_per_sec"]},
            ]},
        }

    warn = params.get("warn", None)
    crit = params.get("crit", None)

    res = ctx.run(_PS_ARGV, mutates=False, ok_codes=[0, 1])
    instances = _parse_wmi(res.stdout)

    if not instances:
        return {
            "changed": False,
            "msg": "Exchange ActiveSync: WMI data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    entry = instances[0]
    raw_val = entry.get("RequestsPersec")
    if raw_val == None:
        return {
            "changed": False,
            "msg": "Exchange ActiveSync: RequestsPersec not found in WMI output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    req_per_sec = float(raw_val)

    state = "OK"
    if crit != None and req_per_sec >= crit:
        state = "CRIT"
    elif warn != None and req_per_sec >= warn:
        state = "WARN"

    msg = "Requests/sec: %f" % req_per_sec

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"requests_per_sec": req_per_sec},
            "details": "",
        },
    }