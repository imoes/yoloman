def main(ctx, params):
    # Read the CPU section from agent output
    res = ctx.run(["cat", "/proc/cpuinfo"], mutates=False)
    lines = res.stdout.splitlines()
    
    # Count logical CPU threads (processors)
    threads_count = 0
    max_threads = 0
    for line in lines:
        if line.startswith("processor"):
            threads_count += 1
        elif line.startswith("CPU cores"):
            cores = line.split(":")[1].strip()
            if cores.isdigit():
                max_threads = int(cores)
        elif line.startswith("Siblings"):
            siblings = line.split(":")[1].strip()
            if siblings.isdigit():
                max_threads = int(siblings)
    
    # If /proc/cpuinfo didn't provide max threads, use threads_count as max for calculation
    if max_threads == 0:
        max_threads = threads_count
    
    # Discovery mode
    if params.get("_discover"):
        if threads_count > 0:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": (2000, 4000)}, "metrics": ["threads", "thread_usage"]}
                ]},
            }
        else:
            return {
                "changed": False,
                "msg": "no threads found",
                "data": {"discovery": []},
            }
    
    # Check mode for item ""
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Get thresholds from params
    levels_param = params.get("levels", ("levels", (2000, 4000)))
    warn = None
    crit = None
    if isinstance(levels_param, tuple) and len(levels_param) == 2:
        levels_tuple = levels_param[1]
        if isinstance(levels_tuple, tuple) and len(levels_tuple) == 2:
            warn = levels_tuple[0]
            crit = levels_tuple[1]
    
    # Determine states and metrics
    metrics = {"threads": threads_count}
    state = "OK"
    details_parts = ["Threads: " + str(threads_count)]
    
    # Calculate usage if max_threads is available and > 0
    if max_threads > 0 and threads_count > 0:
        thread_usage = 100.0 * threads_count / max_threads
        metrics["thread_usage"] = thread_usage
        
        # Check thresholds for usage
        if crit != None and thread_usage >= crit:
            state = "CRIT"
        elif warn != None and thread_usage >= warn:
            state = "WARN" if state != "CRIT" else state
        details_parts.append("Usage: " + str(int(thread_usage)) + "%")
    
    # Check absolute thread count thresholds
    if crit != None and threads_count >= crit:
        state = "CRIT"
    elif warn != None and threads_count >= warn:
        state = "WARN" if state != "CRIT" else state
    
    details = ", ".join(details_parts)
    msg = details
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
