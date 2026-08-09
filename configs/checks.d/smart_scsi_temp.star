def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["smartctl", "--version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "smartctl not installed",
                    "data": {"discovery": []}}

        scan = ctx.run(["smartctl", "--scan"], mutates=False)
        devices = {}
        for line in scan.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            dev = parts[0]
            if "scsi" in dev.lower() or "scs" in dev.lower():
                devices[dev] = True

        out = []
        for dev in sorted(devices):
            res = ctx.run(["smartctl", "-A", dev], mutates=False)
            if res.rc != 0:
                continue
            temp = None
            for l in res.stdout.splitlines():
                if "Temperature" in l or "190 Airflow_Temperature_Cel" in l:
                    cols = l.split()
                    if len(cols) >= 10:
                        v = cols[-1]
                        temp = int(v) if v.lstrip("-").isdigit() else None
                    break
            if temp == None or temp == 0:
                continue
            out.append({"item": dev,
                        "params": {"warn": 35, "crit": 40},
                        "metrics": ["temperature"],
                        "service_labels": {
                            "cmk/smart/type": "SCSI",
                            "cmk/smart/device": dev,
                        }})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["smartctl", "-A", item], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read device " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp = None
    for l in res.stdout.splitlines():
        if "Temperature" in l:
            cols = l.split()
            if len(cols) >= 10:
                v = cols[-1]
                temp = int(v) if v.lstrip("-").isdigit() else None
            break
    if temp == None:
        return {"changed": False, "msg": "no temperature for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", (35, 40))
    warn = levels[0] if len(levels) >= 2 else 35
    crit = levels[1] if len(levels) >= 2 else 40
    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    return {"changed": False,
            "msg": "Temperature: %d C" % temp,
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}