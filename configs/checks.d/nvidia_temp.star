# nvidia_temp.star
# Read-only Starlark check module for NVIDIA GPU temperature sensors
# Uses: nvidia_smi --query-gpu=index,name,temperature.gpu --format=csv,noheader,nounits

def main(ctx, params):
    # Discovery mode: enumerate all temperature sensors
    if params.get("_discover"):
        res = ctx.run([
            "nvidia_smi",
            "--query-gpu=index,name,temperature.gpu",
            "--format=csv,noheader,nounits"
        ], mutates=False)
        out = []
        # Each line: index, name, temp (space-separated in CSV)
        for line in res.stdout.splitlines():
            fields = line.strip().split(",")
            if len(fields) >= 3:
                name = fields[1].strip()
                item = "GPU NVIDIA" if name == "GPU Core" else "System NVIDIA " + name
                out.append({
                    "item": item,
                    "params": {"levels": (60.0, 65.0)},  # Default Checkmk levels
                    "metrics": ["temperature"]
                })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: verify one item's temperature
    item = params.get("item", "")
    warn, crit = params.get("levels", (60.0, 65.0))

    res = ctx.run([
        "nvidia_smi",
        "--query-gpu=index,name,temperature.gpu",
        "--format=csv,noheader,nounits"
    ], mutates=False)

    temp = None
    for line in res.stdout.splitlines():
        fields = line.strip().split(",")
        if len(fields) >= 3:
            name = fields[1].strip()
            check_name = "GPU NVIDIA" if name == "GPU Core" else "System NVIDIA " + name
            if check_name == item:
                temp_str = fields[2].strip()
                if temp_str.isdigit():
                    temp = int(temp_str)
                break

    # If no matching sensor found, return UNKNOWN
    if temp == None:
        return {
            "changed": False,
            "msg": "sensor '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine state based on thresholds
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Temperature: %d °C" % temp,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }