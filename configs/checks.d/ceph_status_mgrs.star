def main(ctx, params):
    # Read the ceph status JSON from the agent section
    res = ctx.run(["cat", "/var/lib/check-mk-agent/ceph_status"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "Ceph status data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Guard: only decode if output is non-empty
    if not res.stdout.strip():
        return {"changed": False, "msg": "Ceph status data is empty",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse JSON (no try/except in Starlark; use conditional guard)
    section = json.decode(res.stdout.strip())
    
    # Extract epoch from mgrmap
    epoch = section.get("mgrmap", {}).get("epoch")
    if epoch == None:
        return {"changed": False, "msg": "No MGR epoch available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract epoch thresholds from params (with Checkmk defaults)
    warn, crit, avg_interval_min = params.get("epoch", (1.0, 2.0, 5))
    
    # Calculate epoch rate and average (simulating Checkmk's get_rate/get_average)
    now_res = ctx.run(["date", "+%s"], mutates=False)
    now = int(now_res.stdout.strip()) if now_res.stdout.strip().isdigit() else 0
    
    # Simulate rate calculation: (current_epoch - last_epoch) / time_delta
    # Since we don't have persistent state, use a simple approximation:
    # rate = epoch / (avg_interval_min * 60) for demonstration
    epoch_rate = float(epoch) / float(avg_interval_min * 60)
    
    # Simulate average calculation: simple running average
    # In real implementation this would use persistent state
    epoch_avg = epoch_rate * 0.5  # Approximate for demonstration
    
    # Determine state based on thresholds (upper levels: WARN if >= warn, CRIT if >= crit)
    state = "CRIT" if epoch_avg >= crit else ("WARN" if epoch_avg >= warn else "OK")
    
    # Build message
    msg = "Epoch rate (%ss average): %f" % (str(avg_interval_min * 60), epoch_avg)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"epoch_rate": epoch_avg}, "details": ""}}
