# MongoDB Locks check - read-only Starlark module
# No parameters accepted; returns single service item with "" name

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["check_mk", "--inventory", "mongodb_locks"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            # Agent not available or no data
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # The agent section exists and produces data
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": [
                    "clients_readers_locks",
                    "clients_total_locks",
                    "clients_writers_locks",
                    "queue_readers_locks",
                    "queue_total_locks",
                    "queue_writers_locks"
                ]}]}}
    
    # Check mode
    # Run agent directly to get section data (raw inventory output)
    res = ctx.run(["check_mk", "--inventory", "mongodb_locks"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "mongodb_locks data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the section output manually (check_mk --inventory returns raw section)
    # Format: what name count, e.g. "activeClients readers 0"
    lines = res.stdout.splitlines()
    if not lines:
        return {"changed": False, "msg": "mongodb_locks section empty",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    metrics = {}
    details_parts = []
    
    for line in lines:
        parts = line.split()
        if len(parts) != 3:
            continue
        what, name, count_str = parts
        # Guard instead of try/except
        count = int(count_str) if count_str.isdigit() else 0
        
        param_name = "clients" if what.startswith("active") else "queue"
        metric_name = param_name + "_" + name + "_locks"
        label = param_name.title() + "-" + name.title()
        
        metrics[metric_name] = count
        details_parts.append("%s: %d" % (label, count))
    
    # Determine state based on thresholds (no thresholds defined in defaults)
    # Checkmk check_levels would use params.get(metric_name, None) for levels
    # Since check_default_parameters={}, all levels are None => always OK
    state = "OK"
    
    return {"changed": False,
            "msg": "; ".join(details_parts) if details_parts else "no metrics",
            "data": {"state": state, "metrics": metrics, "details": ""}}
