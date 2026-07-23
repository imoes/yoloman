def main(ctx, params):
    if params.get("_discover"):
        # Read /proc/meminfo to check for vmalloc data
        content = ctx.file_read("/proc/meminfo")
        section = {}
        for line in content.splitlines():
            if line.strip() == "":
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            key = parts[0].rstrip(":")
            # Only collect the fields we need
            if key in ["VmallocTotal", "VmallocUsed", "VmallocChunk"]:
                # Value is in kB
                val_str = parts[1]
                if val_str.isdigit():
                    section[key] = int(val_str)
                else:
                    section[key] = 0

        # Skip if not Linux (Checkmk section would be "mem" only on Linux)
        os_family = ctx.facts().get("os_family", "")
        if os_family != "linux":
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        # Skip if no vmalloc data
        if "VmallocTotal" not in section:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        # Skip newer kernels reporting wrong data (VmallocUsed=0 AND VmallocChunk=0)
        vmalloc_used = section.get("VmallocUsed", 0)
        vmalloc_chunk = section.get("VmallocChunk", 0)
        vmalloc_total = section.get("VmallocTotal", 0)
        if vmalloc_used == 0 and vmalloc_chunk == 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        # Skip 64-bit systems (infinite vmalloc) - check VmallocTotal < 4 GiB
        if vmalloc_total >= 4 * 1024 * 1024:  # 4*1024^2 in kB = 4 GiB
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        # Single-service check: item is ""
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {
                "levels_used_perc": (80.0, 90.0),
                "levels_lower_chunk_mb": (64, 32)
            }, "metrics": ["used", "chunk"]}]}
        }

    # Check mode
    content = ctx.file_read("/proc/meminfo")
    section = {}
    for line in content.splitlines():
        if line.strip() == "":
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        key = parts[0].rstrip(":")
        if key in ["VmallocTotal", "VmallocUsed", "VmallocChunk"]:
            val_str = parts[1]
            if val_str.isdigit():
                section[key] = int(val_str)
            else:
                section[key] = 0

    # If data missing or invalid, return UNKNOWN
    if "VmallocTotal" not in section:
        return {
            "changed": False,
            "msg": "no vmalloc data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    vmalloc_total_kb = section.get("VmallocTotal", 0)
    vmalloc_used_kb = section.get("VmallocUsed", 0)
    vmalloc_chunk_kb = section.get("VmallocChunk", 0)

    # Convert to MB
    total_mb = float(vmalloc_total_kb) / (1024.0 * 1024.0)
    used_mb = float(vmalloc_used_kb) / (1024.0 * 1024.0)
    chunk_mb = float(vmalloc_chunk_kb) / (1024.0 * 1024.0)

    # Extract thresholds with defaults
    levels_used_perc = params.get("levels_used_perc", (80.0, 90.0))
    levels_lower_chunk_mb = params.get("levels_lower_chunk_mb", (64, 32))
    warn_used_perc, crit_used_perc = levels_used_perc

    # Calculate absolute levels
    warn_used_mb = total_mb * warn_used_perc / 100.0
    crit_used_mb = total_mb * crit_used_perc / 100.0
    warn_chunk_mb, crit_chunk_mb = levels_lower_chunk_mb

    # Determine states
    state = "OK"
    details_parts = []
    details_parts.append("Total: %f MB" % total_mb)

    # Used level check (upper levels)
    if crit_used_mb > 0 and used_mb >= crit_used_mb:
        state = "CRIT"
    elif warn_used_mb > 0 and used_mb >= warn_used_mb:
        state = "WARN"

    # Largest chunk check (lower levels)
    if crit_chunk_mb > 0 and chunk_mb <= crit_chunk_mb:
        state = "CRIT"
    elif warn_chunk_mb > 0 and chunk_mb <= warn_chunk_mb:
        state = "WARN"

    # Build message
    msg = "Total: %f MB, Used: %f MB, Largest chunk: %f MB" % (total_mb, used_mb, chunk_mb)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used": used_mb, "chunk": chunk_mb},
            "details": ""
        }
    }