def main(ctx, params):
    # Probe for the real thing - nvidia-smi must exist
    probe = ctx.run(["nvidia-smi", "--query-gpu=name,temperature.gpu", "--format=csv,noheader,nounits"], mutates=False)
    if probe.rc == 127:
        if params.get("_discover"):
            return {"changed": False, "msg": "nvidia-smi not found, discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "no NVIDIA GPU found (nvidia-smi not installed)", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if probe.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "nvidia-smi failed, discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "failed to query NVIDIA GPU: " + probe.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the nvidia-smi output - one line per GPU
    lines = probe.stdout.strip().splitlines()
    if len(lines) == 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no NVIDIA GPUs found, discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "no NVIDIA GPU found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Format helper matching Checkmk's _format_nvidia_name
    def _format_name(identifier):
        # For nvidia-smi, each GPU is just "GPU" - we use the GPU index/name
        return "GPU NVIDIA"

    if params.get("_discover"):
        discovery_list = []
        for i, line in enumerate(lines):
            parts = line.split(",")
            if len(parts) < 2:
                continue
            name = parts[0].strip()
            # Use the GPU name as the item, matching Checkmk's service naming
            item = "GPU NVIDIA" if i == 0 else "GPU NVIDIA " + str(i)
            discovery_list.append({
                "item": item,
                "params": {"levels": (60.0, 65.0)},
                "metrics": ["temperature"]
            })
        msg = "discovered %d NVIDIA GPU temperatures" % len(discovery_list)
        return {"changed": False, "msg": msg, "data": {"discovery": discovery_list}}

    # Check mode - check one specific GPU
    item = params.get("item", "")
    # Parse temperatures
    temps = []
    for i, line in enumerate(lines):
        parts = line.split(",")
        if len(parts) < 2:
            continue
        temp_str = parts[1].strip()
        temp_val = int(temp_str) if temp_str.isdigit() else 0
        name = "GPU NVIDIA" if i == 0 else "GPU NVIDIA " + str(i)
        temps.append((name, temp_val))

    # Find the matching item
    target_temp = None
    for gpu_name, temp in temps:
        if item == "" and target_temp == None:
            target_temp = temp
            break
        if item == gpu_name:
            target_temp = temp
            break

    if target_temp == None:
        return {"changed": False, "msg": "no such NVIDIA GPU: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply temperature thresholds from params (Checkmk defaults: 60/65 for non-core)
    levels = params.get("levels", (60.0, 65.0))
    warn = levels[0] if isinstance(levels, list) else levels[0]
    crit = levels[1] if isinstance(levels, list) else levels[1]

    state = "OK"
    if target_temp >= crit:
        state = "CRIT"
    elif target_temp >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Temperature %s: %f C" % (item, target_temp),
        "data": {
            "state": state,
            "metrics": {"temperature": target_temp},
            "details": ""
        }
    }