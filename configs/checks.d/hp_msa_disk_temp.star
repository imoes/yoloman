def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "Disks", "params": {"levels": [40.0, 45.0]}, "metrics": ["disk_temp"]}]},
        }

    item = params.get("item", "")
    if item != "Disks":
        return {
            "changed": False,
            "msg": "unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, "1.3.6.1.4.1.232.6.2.6.1.1.1.6"], mutates=False)
    
    if not res.stdout:
        return {
            "changed": False,
            "msg": "no disk temperature data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    temps = []
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 4 and parts[2].startswith("INTEGER:"):
            temp_str = parts[3]
            is_neg = temp_str.startswith("-")
            rest = temp_str[1:] if is_neg else temp_str
            if rest.isdigit() or rest.replace(".", "", 1).isdigit():
                temp = float(temp_str)
                temps.append(temp)

    if not temps:
        return {
            "changed": False,
            "msg": "no disk temperature values found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Manual sum since Starlark lacks built-in sum
    total = 0.0
    for t in temps:
        total = total + t
    avg_temp = total / len(temps)
    max_temp = temps[0]
    for t in temps[1:]:
        if t > max_temp:
            max_temp = t

    warn = params.get("levels", [40.0, 45.0])
    warn_upper = warn[0]
    crit_upper = warn[1]

    if max_temp >= crit_upper:
        state = "CRIT"
    elif max_temp >= warn_upper:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Temperature: %f C (max)" % max_temp,
        "data": {
            "state": state,
            "metrics": {
                "disk_temp": avg_temp,
            },
            "details": "",
        },
    }