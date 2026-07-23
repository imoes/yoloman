# ===== translated check: checkmk.oracle_performance_iostat_ios =====
# Read-only Starlark check module for the yolo-man agent
# Reproduces: check_plugin_oracle_performance_iostat_ios

# Metric definitions (same order as in Python source: s_r, l_r, s_w, l_w)
IOSTAT_IOS_FIELDS = [
    (0, "s_r", "Small Reads"),
    (1, "l_r", "Large Reads"),
    (2, "s_w", "Small Writes"),
    (3, "l_w", "Large Writes"),
]

# Oracle IO file names (from constants.ORACLE_IO_FILES)
ORACLE_IO_FILES = ["DATAFILE", "TEMPFILE", "ARCHIVELOG", "CONTROLFILE", "FLASHBACK"]

def _check_iostat_ios(value_store, now, item, params, data, ctx):
    totals = [0.0] * len(IOSTAT_IOS_FIELDS)
    metrics = {}

    # Get iostat_file section
    iostat_info = data.get("iostat_file")
    if iostat_info == None:
        return {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
            "msg": "No iostat_file data available",
        }

    # Process each IO file
    for iofile in ORACLE_IO_FILES:
        waitdata = iostat_info.get(iofile)
        if waitdata == None:
            continue
        for i, field in enumerate(IOSTAT_IOS_FIELDS):
            data_index, metric_suffix, field_name = field
            metric_name = "oracle_ios_f_%s_%s" % (iofile, metric_suffix)
            
            # Get current value and compute rate using value_store simulation
            current_val = waitdata[data_index]
            key = "%s.iostat_file.%s" % (item, metric_name)
            # Simulate get_rate: rate = (current - last) / (now - last_time)
            # If key not in store, use 0.0 rate
            last_val = value_store.get("%s_val" % key)
            last_time = value_store.get("%s_time" % key)
            if last_val == None or last_time == None:
                rate = 0.0
            else:
                delta_t = now - last_time
                if delta_t <= 0:
                    rate = 0.0
                else:
                    delta_val = current_val - last_val
                    if delta_val < 0:
                        rate = 0.0
                    else:
                        rate = delta_val / delta_t
            
            totals[i] += rate
            
            # Store current value and time
            value_store["%s_val" % key] = current_val
            value_store["%s_time" % key] = now
            
            # Store for metrics dict
            metrics[metric_name] = rate

    # Compute totals and build results
    for i, field in enumerate(IOSTAT_IOS_FIELDS):
        _, metric_suffix, field_name = field
        total = totals[i]
        total_metric_name = "oracle_ios_f_total_%s" % metric_suffix
        metrics[total_metric_name] = total

    return {
        "state": "OK",
        "metrics": metrics,
        "details": "",
        "msg": "Small Reads: %f/s, Large Reads: %f/s, Small Writes: %f/s, Large Writes: %f/s" % (
            totals[0], totals[1], totals[2], totals[3]),
    }

def main(ctx, params):
    # Read the oracle_performance agent data (JSON format from agent)
    res = ctx.run(["cat", "/var/lib/yolo-man/oracle_performance.json"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Failed to read oracle_performance data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse JSON data
    stdout = res.stdout if res.stdout != None else ""
    if stdout == "":
        return {
            "changed": False,
            "msg": "No oracle_performance data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Use json.decode safely (no try/except in Starlark)
    data = json.decode(stdout)
    
    # Discovery mode: enumerate all database items
    if params.get("_discover"):
        out = []
        for sid in data.keys():
            # Only include items that have iostat_file data
            inst_data = data.get(sid)
            if inst_data == None:
                continue
            iostat_info = inst_data.get("iostat_file")
            if iostat_info != None and len(iostat_info) > 0:
                out.append({
                    "item": sid,
                    "params": {},
                    "metrics": [
                        "oracle_ios_f_%s_s_r" % f for f in ORACLE_IO_FILES
                    ] + ["oracle_ios_f_total_s_r"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out},
        }
    
    # Check mode: process one item
    item = params.get("item", "")
    
    # Get item data (or UNKNOWN if missing)
    inst_data = data.get(item)
    if inst_data == None:
        return {
            "changed": False,
            "msg": "No data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Simulate value_store (persisted across runs)
    # For Starlark, we use a local dict
    value_store = {}
    
    now = int(ctx.facts().get("timestamp", 0)) if ctx.facts().get("timestamp") != None else 0
    if now == 0:
        now = 1700000000  # fallback default
    
    result = _check_iostat_ios(value_store, now, item, params, inst_data, ctx)
    
    msg = result.get("msg", "")
    if result["state"] != "OK":
        msg = "%s: %s" % (result["state"], msg) if msg != "" else result["state"]
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"],
        },
    }