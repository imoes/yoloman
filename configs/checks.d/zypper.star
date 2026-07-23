def main(ctx, params):
    # Read zypper output (agent section zypper)
    res = ctx.run(["zypper", "list-updates"], mutates=False)
    if res.rc != 0:
        # Fallback: some environments may require --no-remote
        res = ctx.run(["zypper", "--no-remote", "list-updates"], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "zypper command failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    if not lines:
        return {"changed": False, "msg": "zypper list-updates returned no output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    firstline = " ".join(lines[0].split()) if lines else ""
    if firstline.startswith("ERROR:"):
        return {"changed": False, "msg": firstline,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    patch_types = []
    locks = []
    
    # Parse zypper list-updates output
    # Typical format (varies by zypper version):
    # | <status> | <name> | <version> | <arch> | <patch-type> | <needed> |
    # We look for lines where the last field contains "needed" (case-insensitive)
    for line in lines:
        fields = line.split()
        if len(fields) < 4:
            continue
        
        # Check if line contains lock entries (second field format)
        # Lock format: "<lock-id>" in second field, with no status field
        if len(fields) == 4 and not fields[0].startswith("|") and fields[1].strip() != "":
            locks.append(line.strip())
            continue
        
        # Try to find patch type and needed status
        # Last field (or near last) may contain "Needed", "needed", etc.
        needed_field = fields[-1].lower() if fields else ""
        if needed_field == "needed" or needed_field == "needed)":
            # Patch type is usually in the 5th field (0-indexed: 4)
            # but varies: try different positions
            pt = None
            if len(fields) >= 5:
                pt = fields[4].strip().rstrip("|").rstrip(":").rstrip()
            elif len(fields) >= 4:
                pt = fields[3].strip().rstrip("|").rstrip(":").rstrip()
            
            if pt:
                patch_types.append(pt)
    
    # Determine state based on patch types
    # Defaults (Checkmk default): locks=WARN, security=CRIT, recommended=WARN, other=OK
    locks_count = len(locks)
    security_count = patch_types.count("security")
    recommended_count = patch_types.count("recommended")
    other_count = len(patch_types) - security_count - recommended_count
    total_updates = len(patch_types)
    
    state = "OK"
    messages = []
    
    # Check for security patches (most severe)
    if security_count > 0:
        state = "CRIT"
        messages.append("security: %d" % security_count)
    
    # Check for recommended patches
    elif recommended_count > 0:
        if state != "CRIT":
            state = "WARN"
        messages.append("recommended: %d" % recommended_count)
    
    # Check for other patches
    elif other_count > 0:
        messages.append("other: %d" % other_count)
    
    # Locks
    if locks_count > 0:
        if state == "OK":
            state = "WARN"
        messages.append("locks: %d" % locks_count)
    
    # Build summary message
    summary = "%d updates" % total_updates
    if messages:
        summary += " (%s)" % ", ".join(messages)
    
    # Return results
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {
                "security_patches": security_count,
                "recommended_patches": recommended_count,
                "other_patches": other_count,
                "locks": locks_count,
                "total_patches": total_updates
            }, "details": ""}}
