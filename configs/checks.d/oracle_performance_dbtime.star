def main(ctx, params):
    # Discovery mode: enumerate all Oracle instances from the agent output
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/oracle_performance"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read oracle_performance data",
                    "data": {"discovery": []}}
        items = set()
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split("|")
            if len(parts) >= 1:
                items.add(parts[0])
        discovery = []
        for item in sorted(items):
            discovery.append({"item": item, "params": {}, "metrics": ["oracle_db_time", "oracle_db_cpu", "oracle_db_wait_time"]})
        return {"changed": False, "msg": "discovered %d instances" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode: check one instance
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/oracle_performance"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read oracle_performance data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse sys_time_model entries for this instance
    sys_time_model = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) >= 4 and parts[0] == item and parts[1] == "sys_time_model":
            if parts[2] in ["DB CPU", "DB time"]:
                val_str = parts[3]
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    sys_time_model[parts[2]] = int(val_str)
    
    # If no sys_time_model data exists, report UNKNOWN
    if not sys_time_model:
        return {"changed": False, "msg": "no sys_time_model data for instance",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract cpu_time and db_time
    cpu_time = sys_time_model.get("DB CPU", 0)
    db_time = sys_time_model.get("DB time", 0)
    wait_time = db_time - cpu_time
    
    # Calculate rates (delta over time) using value store
    # Since Starlark has no persistent state, we compute rates based on the raw values
    # and simulate the rate calculation by dividing by an assumed time window (e.g. 300s)
    # This is a limitation of Starlark check modules without value store persistence.
    # For production, this would require persistent state storage, but we follow the spec.
    time_window = 300.0  # assume 5 minute check interval
    
    db_time_rate = float(db_time) / time_window
    cpu_time_rate = float(cpu_time) / time_window
    wait_time_rate = float(wait_time) / time_window
    
    # Determine states based on levels
    # Default: no levels defined in Checkmk check_default_parameters
    db_time_warn = params.get("oracle_db_time")
    db_time_crit = params.get("oracle_db_time")
    if type(db_time_warn) == "list":
        db_time_warn = db_time_warn[1] if len(db_time_warn) > 1 else None
        if type(db_time_crit) == "list":
            db_time_crit = db_time_crit[1] if len(db_time_crit) > 1 else None
        else:
            db_time_crit = None
    else:
        db_time_warn = None
        db_time_crit = None
    
    # Determine state for each metric
    state = "OK"
    details = []
    
    for metric, rate, name in [
        ("oracle_db_time", db_time_rate, "DB Time"),
        ("oracle_db_cpu", cpu_time_rate, "DB CPU"),
        ("oracle_db_wait_time", wait_time_rate, "DB Non-Idle Wait"),
    ]:
        # Check upper levels (warn/crit thresholds)
        if db_time_crit != None and rate >= db_time_crit:
            state = "CRIT"
        elif db_time_warn != None and rate >= db_time_warn:
            state = "WARN" if state == "OK" else state
        
        details.append("%s: %f/s" % (name, rate))
    
    # Build metrics dict
    metrics = {
        "oracle_db_time": db_time_rate,
        "oracle_db_cpu": cpu_time_rate,
        "oracle_db_wait_time": wait_time_rate,
    }
    
    return {
        "changed": False,
        "msg": ", ".join(details),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }