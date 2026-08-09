# openhardwaremonitor_fan — read-only Starlark check module
# Reproduces the Checkmk openhardwaremonitor Fan sub-check.
# OpenHardwareMonitor is a Windows-only GUI tool; there is no on-host source
# for it on the host this agent runs on, so discovery is empty and items
# report UNKNOWN.

def main(ctx, params):
    present = False
    res = ctx.run(["OpenHardwareMonitor", "--version"], mutates=False)
    if res.rc == 127:
        present = False
    else:
        present = res.rc == 0 and bool(res.stdout and res.stdout.strip())

    if params.get("_discover"):
        if not present:
            return {"changed": False, "msg": "OpenHardwareMonitor not installed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no OpenHardwareMonitor fan data available",
                "data": {"discovery": []}}

    item = params.get("item", "")
    if not present:
        return {"changed": False, "msg": "OpenHardwareMonitor not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False,
            "msg": "no OpenHardwareMonitor fan data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}