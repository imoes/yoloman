# Constants for the counters we care about
_WANT_COUNTERS = ["batch_requests/sec", "sql_compilations/sec", "sql_re-compilations/sec"]

def _get_item_from_service(item, section):
    """Parse the item string into (counter, counter_name) based on service item format"""
    parts = item.split(" ", 2)
    if len(parts) != 3:
        return None, None
    obj_instance = parts[0] + " " + parts[1]
    counter = parts[2]
    # Find matching section entry
    for (obj, instance), counters in section.items():
        if obj == parts[0] and instance == parts[1]:
            if counter in counters:
                return counters, counter
    return None, None

def _check_levels(rate, levels_upper, metric_name, node_name):
    """Mimic check_levels_v1 behavior for upper levels"""
    if levels_upper == None:
        return "OK", "no levels defined"
    
    warn = levels_upper.get("warn")
    crit = levels_upper.get("crit")
    
    if crit != None and rate >= crit:
        return "CRIT", "%s%f/s >= %s" % (node_name and "[%s] " % node_name, rate, str(crit))
    elif warn != None and rate >= warn:
        return "WARN", "%s%f/s >= %s" % (node_name and "[%s] " % node_name, rate, str(warn))
    else:
        return "OK", "%s%f/s" % (node_name and "[%s] " % node_name, rate)

def main(ctx, params):
    # Discovery mode: enumerate all matching counters
    if params.get("_discover"):
        # Get agent section data via run command (mssql_counters agent section)
        res = ctx.run(["cat", "/tmp/mssql_counters.json"], mutates=False)
        if res.rc != 0 or res.stdout.strip() == "":
            # Fallback to parsing /proc or agent data if needed, but use JSON format
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        section = json.decode(res.stdout) if res.stdout.strip() != "" else {}
        
        items = []
        for (obj, instance), counters in section.items():
            for counter in counters:
                if counter in _WANT_COUNTERS:
                    item_name = obj + " " + instance + " " + counter
                    items.append({
                        "item": item_name,
                        "params": {},
                        "metrics": [counter.replace("/sec", "_per_second")]
                    })
        
        return {"changed": False, "msg": "discovered %d items" % len(items), 
                "data": {"discovery": items}}
    
    # Check mode: process one item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get agent section data
    res = ctx.run(["cat", "/tmp/mssql_counters.json"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read agent data", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = json.decode(res.stdout) if res.stdout.strip() != "" else {}
    
    counters, counter = _get_item_from_service(item, section)
    if counters == None or counter == None:
        return {"changed": False, "msg": "item not found", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get current value and UTC time
    current_value = counters.get(counter, 0)
    utc_time = counters.get("utc_time", 0)
    
    # Get previous value from persistent state (simulated via file in this environment)
    state_file = "/tmp/mssql_counter_state_%s.json" % item.replace(":", "_").replace("/", "_")
    
    prev_state = {}
    if ctx.file_exists(state_file):
        prev_state_str = ctx.file_read(state_file)
        if prev_state_str.strip() != "":
            prev_state = json.decode(prev_state_str)
    
    # Check if we have previous data to compute rate
    if prev_state.get("time") != None and prev_state.get("value") != None and utc_time != 0:
        # Rate = (current - prev) / (utc_time - prev_time)
        # Since Checkmk agent provides utc_time in seconds, use that as time delta
        time_diff = float(utc_time - prev_state.get("time", utc_time))
        if time_diff <= 0:
            return {"changed": False, "msg": "invalid time delta", 
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        value_diff = float(current_value - prev_state.get("value", current_value))
        rate = value_diff / time_diff
    else:
        # Cannot calculate rate yet
        return {"changed": False, "msg": "Cannot calculate rates yet", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Save current state for next check
    if not ctx.check_mode:
        new_state = {"time": utc_time, "value": current_value}
        ctx.file_write(state_file, json.encode(new_state))
    
    # Apply thresholds
    levels = params.get(counter)
    metric_name = counter.replace("/sec", "_per_second")
    
    state, summary = _check_levels(rate, levels, metric_name, "")
    
    # Format return value
    if state == "OK":
        state_num = "OK"
    elif state == "WARN":
        state_num = "WARN"
    else:
        state_num = "CRIT"
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_num,
            "metrics": {metric_name: rate},
            "details": ""
        }
    }