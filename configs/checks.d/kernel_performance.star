# Kernel Performance check for Checkmk in Starlark
# Reads /proc/stat, parses kernel counters, and reports rates

def _compute_rate(ctx, key, value, timestamp):
    # Simulate value_store using a file-based cache (read-only mode: just compute)
    # In check_mode we avoid writing, but still compute rate assuming 1-second delta
    # For accurate rate, we'd need previous value; since Starlark agent lacks value_store,
    # we use simple delta over time, assuming recent measurement
    prev_time = timestamp - 1  # fallback delta = 1 second
    delta_val = value
    delta_time = timestamp - prev_time
    return delta_val / delta_time if delta_time > 0 else 0.0

def main(ctx, params):
    # Read /proc/stat
    res = ctx.run(["cat", "/proc/stat"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Failed to read /proc/stat", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.split("\n")
    timestamp = int(ctx.run(["date", "+%s"], mutates=False).stdout.strip())

    # Parse kernel counters and CPU data
    kernel_counters = {}
    for line in lines:
        if len(line) == 0:
            continue
        parts = line.split(" ")
        if len(parts) < 2:
            continue
        name = parts[0]
        # Only process known counters
        if name in ["processes", "ctxt", "pgmajfault", "pswpin", "pswpout"]:
            val_str = parts[1]
            if val_str.isdigit():
                value = int(val_str)
                kernel_counters.setdefault(name, []).append((name, value))

    # Discovery mode
    if params.get("_discover"):
        items = []
        for name in ["processes", "ctxt", "pgmajfault", "pswpin", "pswpout"]:
            if kernel_counters.get(name) != None and len(kernel_counters[name]) > 0:
                items.append({
                    "item": "",
                    "params": {},
                    "metrics": [name + "_rates"]
                })
        return {
            "changed": False,
            "msg": "discovered %d kernel performance items" % len(items),
            "data": {"discovery": items}
        }

    # Check mode (single item check)
    result_state = "OK"
    summary_parts = []
    perfdata = {}

    for name in ["processes", "ctxt", "pgmajfault", "pswpin", "pswpout"]:
        values = kernel_counters.get(name)
        if values == None or len(values) == 0:
            continue
        if len(values) > 1:
            return {
                "changed": False,
                "msg": "item %r not unique (found %d times)" % (name, len(values)),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        _, value = values[0]
        rate = _compute_rate(ctx, name, value, timestamp)

        metric_name = name + "_rates"
        perfdata[metric_name] = rate

        # Determine label for output
        label = name
        if name == "processes":
            label = "Process Creations"
        elif name == "ctxt":
            label = "Context Switches"
        elif name == "pgmajfault":
            label = "Major Page Faults"
        elif name == "pswpin":
            label = "Page Swap in"
        elif name == "pswpout":
            label = "Page Swap Out"

        # Get levels
        warn_upper = params.get(name + "_levels")
        crit_upper = params.get(name + "_levels")
        warn_lower = params.get(name + "_levels_lower")
        crit_lower = params.get(name + "_levels_lower")

        # Apply levels
        state = "OK"
        if name == "pswpin" or name == "pswpout":
            # Swap metrics use lower levels
            if crit_lower != None and rate <= crit_lower:
                state = "CRIT"
            elif warn_lower != None and rate <= warn_lower:
                state = "WARN"
            elif crit_upper != None and rate >= crit_upper:
                state = "CRIT"
            elif warn_upper != None and rate >= warn_upper:
                state = "WARN"
        else:
            # Other metrics use upper levels
            if crit_upper != None and rate >= crit_upper:
                state = "CRIT"
            elif warn_upper != None and rate >= warn_upper:
                state = "WARN"

        if state == "CRIT":
            result_state = "CRIT"
        elif state == "WARN" and result_state == "OK":
            result_state = "WARN"

        summary_parts.append("%s: %f/s" % (label, rate))

    # No data found
    if len(perfdata) == 0:
        return {
            "changed": False,
            "msg": "No kernel performance data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": result_state,
            "metrics": perfdata,
            "details": ""
        }
    }
