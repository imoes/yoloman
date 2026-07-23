def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/siemens_plc"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read siemens_plc data",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        discovered = []
        for line in lines:
            parts = line.split()
            if len(parts) >= 3 and parts[1] == "temp":
                item = parts[0] + " " + parts[2]
                discovered.append({
                    "item": item,
                    "params": {"warn": 70.0, "crit": 80.0},
                    "metrics": ["temp"]
                })
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovered),
                "data": {"discovery": discovered}}

    # Check mode
    item = params.get("item", "")
    warn = params.get("warn", 70.0)
    crit = params.get("crit", 80.0)

    res = ctx.run(["cat", "/proc/siemens_plc"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read siemens_plc data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp = None
    lines = res.stdout.splitlines()
    for line in lines:
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "temp":
            candidate = parts[0] + " " + parts[2]
            if candidate == item:
                val_str = parts[-1]
                if val_str.replace(".", "", 1).replace("-", "", 1).isdigit():
                    temp = float(val_str)
                else:
                    temp = None
                break

    if temp == None:
        return {"changed": False, "msg": "temperature sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Determine state based on thresholds
    state = "OK"
    message_parts = ["%f" % temp + " C"]
    if temp >= crit:
        state = "CRIT"
        message_parts.append(">= %f" % crit + " C")
    elif temp >= warn:
        state = "WARN"
        message_parts.append(">= %f" % warn + " C")

    return {
        "changed": False,
        "msg": " ".join(message_parts),
        "data": {
            "state": state,
            "metrics": {"temp": temp},
            "details": ""
        }
    }