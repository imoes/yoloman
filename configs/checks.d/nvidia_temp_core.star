def main(ctx, params):
    # Discovery mode: enumerate NVIDIA temperature sensors
    if params.get("_discover"):
        res = ctx.run(["nvidia-smi", "--query-gpu=name,temperature.gpu", "--format=csv,noheader,nounits"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to query NVIDIA sensors", "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            parts = line.split(", ")
            if len(parts) >= 2:
                name = parts[0].strip()
                # Only report GPU temperature (temperature.gpu field)
                # Filter for core temperature items only (as per check_plugin_nvidia_temp_core)
                # In the original, _discover_nvidia_temp(True, section) yields only "GPUCoreTemp" items
                # Since nvidia-smi doesn't expose sensor names, we map "GPUCoreTemp" to the GPU temperature
                items.append({"item": "GPUCore", "params": {"levels": (90.0, 95.0)}, "metrics": ["temperature"]})
        
        # Single-item check for core temperature
        if not items:
            items.append({"item": "GPUCore", "params": {"levels": (90.0, 95.0)}, "metrics": ["temperature"]})
        
        return {"changed": False, "msg": "discovered %d temperature sensor(s)" % len(items),
                "data": {"discovery": items}}

    # Check mode: verify a specific item
    item = params.get("item", "")
    # Only support "GPUCore" as per check_plugin_nvidia_temp_core logic
    if item != "GPUCore":
        return {"changed": False, "msg": "unsupported item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Query GPU temperature
    res = ctx.run(["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to query GPU temperature",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    out = res.stdout.strip()
    if not out or not out.replace(".", "").isdigit():
        return {"changed": False, "msg": "invalid GPU temperature reading",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp = float(out)
    warn, crit = params.get("levels", (90.0, 95.0))

    # Checkmk temperature check logic: upper levels
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Temperature: %f °C (warn: %f °C, crit: %f °C)" % (temp, warn, crit),
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }