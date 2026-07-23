def main(ctx, params):
    # Determine mode: discovery or check
    if params.get("_discover"):
        return _discovery(ctx, params)
    else:
        return _check(ctx, params)


def _discovery(ctx, params):
    # Probe for sensor data: run the same command the Checkmk agent would use
    res = ctx.run(["openhardwaremonitor"], mutates=False)
    if res.rc != 0:
        # Agent not installed or not runnable - no services discovered
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    # Parse the raw output
    lines = res.stdout.splitlines()
    items = []
    for line in lines:
        if line.startswith("Index,"):
            continue  # Skip header
        parts = line.split(",")
        if len(parts) < 5:
            continue
        # sensor_type is at index 3
        sensor_type = parts[3]
        if sensor_type != "Temperature":
            continue
        name = parts[1]
        parent = parts[2]
        full_name = _create_full_name(parent, name)
        items.append({
            "item": full_name,
            "params": {"levels": (70, 80)},
            "metrics": ["temperature"]
        })

    return {"changed": False, "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items}}


def _check(ctx, params):
    item = params.get("item", "")
    # Get thresholds - default to Checkmk defaults for temperature
    levels = params.get("levels", (70, 80))
    warn = float(levels[0])
    crit = float(levels[1])

    # Run the probe to get current temperature data
    res = ctx.run(["openhardwaremonitor"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "agent not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse output and find the requested item
    lines = res.stdout.splitlines()
    for line in lines:
        if line.startswith("Index,"):
            continue
        parts = line.split(",")
        if len(parts) < 5:
            continue
        sensor_type = parts[3]
        if sensor_type != "Temperature":
            continue
        name = parts[1]
        parent = parts[2]
        full_name = _create_full_name(parent, name)
        if full_name == item:
            value_str = parts[4] if len(parts) > 4 else ""
            value = float(value_str) if value_str != "" and value_str.replace(".", "").replace("-", "").isdigit() else 0.0
            
            # Determine state
            state = "OK"
            if value >= crit:
                state = "CRIT"
            elif value >= warn:
                state = "WARN"
            
            # Format message
            msg = "Temperature: %f°C" % value

            return {"changed": False, "msg": msg,
                    "data": {"state": state,
                             "metrics": {"temperature": value},
                             "details": ""}}

    # Item not found in output
    return {"changed": False, "msg": "sensor %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}


def _create_full_name(parent, name):
    # Reproduce Checkmk's name normalization logic
    parent = parent.replace("/intelcpu", "cpu")
    parent = parent.replace("/amdcpu", "cpu")
    parent = parent.replace("/genericcpu", "cpu")
    parent = parent.replace("/", "")

    name = name.replace("CPU ", "")
    name = name.replace("Temperature", "")

    return (parent + " " + name).strip()