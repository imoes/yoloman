def main(ctx, params):
    # Read the hint file from the agent output location
    # The Checkmk agent section expects this file to exist at a fixed path
    # We assume the agent has already placed it here (same path the Checkmk agent plugin reads)
    hint_file = "/var/lib/sylo/sylo.hint"
    
    # Try to read the hint file
    if not ctx.file_exists(hint_file):
        return {
            "changed": False,
            "msg": "No hint file (sylo probably never ran on this system)",
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
    
    content = ctx.file_read(hint_file)
    lines = content.splitlines()
    
    # Check if we have valid hint file format (4 lines)
    if len(lines) != 1 or len(lines[0].strip().split()) != 4:
        # Single line expected, check content
        parts = content.strip().split()
        if len(parts) != 4:
            return {
                "changed": False,
                "msg": "Invalid hint file contents: %s" % content.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        lines = [content.strip()]
    
    # Extract values from hint file
    mtime_str, inOffset_str, outOffset_str, size_str = lines[0].strip().split()
    mtime = int(mtime_str)
    inOffset = int(inOffset_str)
    outOffset = int(outOffset_str)
    size = int(size_str)
    
    size_mb = size / (1024.0 * 1024.0)
    
    # Get thresholds from params with Checkmk defaults
    levels_usage_perc = params.get("levels_usage_perc", (5.0, 25.0))
    usage_warn_perc, usage_crit_perc = levels_usage_perc
    max_age_secs = params.get("max_age_secs", 70)
    
    # CRIT: too old
    now = int(ctx.run(["date", "+%s"], mutates=False).stdout.strip())
    age = now - mtime
    if age > max_age_secs:
        return {
            "changed": False,
            "msg": "Sylo not running (Hintfile too old: last update %d secs ago)" % age,
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
    
    # Current fill state
    if inOffset == outOffset:
        bytesUsed = 0
    elif inOffset > outOffset:
        bytesUsed = inOffset - outOffset
    else:
        bytesUsed = size - outOffset + inOffset
    
    if size == 0:
        percUsed = 0.0
    else:
        percUsed = float(bytesUsed) / size * 100
    used_mb = bytesUsed / (1024.0 * 1024.0)
    
    warn_mb = size_mb * usage_warn_perc / 100.0
    crit_mb = size_mb * usage_crit_perc / 100.0
    
    # Determine state
    state = "CRIT" if percUsed >= usage_crit_perc else ("WARN" if percUsed >= usage_warn_perc else "OK")
    
    # For rates we would need to track previous values in value_store
    # Since Starlark has no persistent storage, we'll report 0.0 for rates
    # In a real implementation, the agent would provide this data directly
    in_rate = 0.0
    out_rate = 0.0
    
    msg = "Silo is filled %fMB (%f%%), in %f B/s, out %f B/s" % (used_mb, percUsed, in_rate, out_rate)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "in": in_rate,
                "out": out_rate,
                "used": used_mb
            },
            "details": ""
        }
    }