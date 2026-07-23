def main(ctx, params):
    # Read meminfo - this is the same source the Checkmk agent reads
    if not ctx.file_exists("/proc/meminfo"):
        return {
            "changed": False,
            "msg": "Memory check failed: /proc/meminfo not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    content = ctx.file_read("/proc/meminfo")
    meminfo = {}
    for line in content.splitlines():
        parts = line.split(":")
        if len(parts) != 2:
            continue
        key = parts[0].strip()
        value_part = parts[1].strip()
        # Format: "123456 kB" or "123456"
        value = 0
        if "kB" in value_part:
            tokens = value_part.split()
            if len(tokens) >= 1 and tokens[0].isdigit():
                value = int(tokens[0]) * 1024
        else:
            if value_part.isdigit():
                value = int(value_part)
        meminfo[key] = value

    # Handle missing/zero values with defaults to avoid division by zero
    mem_total = meminfo.get("MemTotal", 0)
    mem_free = meminfo.get("MemFree", 0)
    buffers = meminfo.get("Buffers", 0)
    cached = meminfo.get("Cached", 0)
    swap_total = meminfo.get("SwapTotal", 0)
    swap_free = meminfo.get("SwapFree", 0)
    swap_cached = meminfo.get("SwapCached", 0)
    sreclaimable = meminfo.get("SReclaimable", 0)
    shmem = meminfo.get("Shmem", 0)
    page_tables = meminfo.get("PageTables", 0)
    vmalloc_total = meminfo.get("VmallocTotal", 0)
    vmalloc_used = meminfo.get("VmallocUsed", 0)
    vmalloc_chunk = meminfo.get("VmallocChunk", 0)
    vmalloc_chunk = vmalloc_chunk if vmalloc_chunk > 0 else 1  # avoid division issues
    pending_dirty = meminfo.get("Dirty", 0)
    pending_writeback = meminfo.get("Writeback", 0)
    pending_nfs_unstable = meminfo.get("NFS_Unstable", 0)
    pending_bounce = meminfo.get("Bounce", 0)
    pending_writeback_tmp = meminfo.get("WritebackTmp", 0)
    hardware_corrupted = meminfo.get("HardwareCorrupted", 0)
    committed_as = meminfo.get("Committed_AS", 0)
    commit_limit = meminfo.get("CommitLimit", 0)
    mem_available = meminfo.get("MemAvailable", None)

    # Compute augmented values as Checkmk does
    caches = cached + buffers + swap_cached + sreclaimable
    mem_used = mem_total - mem_free - caches if mem_total > 0 else 0
    swap_used = swap_total - swap_free
    total_used = mem_used + swap_used
    total_total = mem_total + swap_total
    pending = pending_dirty + pending_writeback + pending_nfs_unstable + pending_bounce + pending_writeback_tmp

    # Determine thresholds from params with Checkmk defaults
    levels_virtual = params.get("levels_virtual", ("perc_used", (80.0, 90.0)))
    levels_shm = params.get("levels_shm", ("perc_used", (20.0, 30.0)))
    levels_pagetables = params.get("levels_pagetables", ("perc_used", (8.0, 16.0)))
    levels_committed = params.get("levels_committed", ("perc_used", (100.0, 150.0)))
    levels_commitlimit = params.get("levels_commitlimit", ("perc_free", (20.0, 10.0)))
    levels_vmalloc = params.get("levels_vmalloc", ("abs_free", (50*1024*1024, 30*1024*1024)))
    levels_hardwarecorrupted = params.get("levels_hardwarecorrupted", ("abs_used", (1, 1)))

    # Helper to compute state based on percentage
    def check_percent(value, total, levels):
        if total == 0:
            return "UNKNOWN", None
        percent = (value * 100.0) / total
        typ, (warn, crit) = levels
        if typ.startswith("perc_used"):
            if percent >= crit:
                return "CRIT", percent
            elif percent >= warn:
                return "WARN", percent
            else:
                return "OK", percent
        elif typ.startswith("perc_free"):
            # Free level: warn if free <= warn%, crit if free <= crit%
            free_percent = 100.0 - percent
            if free_percent <= crit:
                return "CRIT", free_percent
            elif free_percent <= warn:
                return "WARN", free_percent
            else:
                return "OK", free_percent
        else:
            # Default to used-based
            if percent >= crit:
                return "CRIT", percent
            elif percent >= warn:
                return "WARN", percent
            else:
                return "OK", percent

    # Helper to compute state based on absolute value
    def check_abs(value, total, levels, show_free=False):
        typ, (warn, crit) = levels
        if show_free:
            # For free-based levels (e.g., vmalloc chunk), warn/crit are free thresholds
            free = total - value if total > 0 else 0
            if typ.startswith("abs_free"):
                if free <= crit:
                    return "CRIT", free
                elif free <= warn:
                    return "WARN", free
                else:
                    return "OK", free
            else:
                # Treat as used
                if value >= crit:
                    return "CRIT", value
                elif value >= warn:
                    return "WARN", value
                else:
                    return "OK", value
        else:
            # Used-based absolute
            if value >= crit:
                return "CRIT", value
            elif value >= warn:
                return "WARN", value
            else:
                return "OK", value

    state_overall = "OK"
    msg_parts = []

    # Virtual memory (always shown)
    if total_total > 0:
        s, p = check_percent(total_used, total_total, levels_virtual)
        state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
        msg_parts.append("Virtual: %d%% used" % p if p != None else "Virtual: N/A")
        metrics = {"virtual_used_percent": p if p != None else 0.0}
    else:
        state_overall = "UNKNOWN"
        msg_parts.append("Virtual: no total")
        metrics = {}

    # RAM
    if mem_total > 0:
        s, p = check_percent(mem_used, mem_total, ("perc_used", (80.0, 90.0)))  # default RAM levels
        state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
        msg_parts.append("RAM: %d%% used" % p if p != None else "RAM: N/A")
        metrics["mem_used_percent"] = p if p != None else 0.0
        metrics["mem_used"] = mem_used

    # Swap
    if swap_total > 0:
        s, p = check_percent(swap_used, swap_total, ("perc_used", (80.0, 90.0)))  # default swap levels
        state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
        msg_parts.append("Swap: %d%% used" % p if p != None else "Swap: N/A")
        metrics["swap_used_percent"] = p if p != None else 0.0
        metrics["swap_used"] = swap_used

    # Shared memory
    if mem_total > 0 and shmem >= 0:
        s, p = check_percent(shmem, mem_total, levels_shm)
        state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
        metrics["shmem"] = shmem
        metrics["mem_lnx_shmem_percent"] = p if p != None else 0.0

    # Page tables
    if mem_total > 0 and page_tables >= 0:
        s, p = check_percent(page_tables, mem_total, levels_pagetables)
        state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
        metrics["page_tables"] = page_tables
        metrics["mem_lnx_page_tables_percent"] = p if p != None else 0.0

    # Committed memory
    if total_total > 0 and committed_as >= 0:
        s, p = check_percent(committed_as, total_total, levels_committed)
        state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
        metrics["committed_as"] = committed_as
        metrics["mem_lnx_committed_as_percent"] = p if p != None else 0.0

    # Commit limit (free %)
    if total_total > 0 and commit_limit >= 0:
        free_commit = total_total - commit_limit
        typ, (warn, crit) = levels_commitlimit
        if typ.startswith("perc_free"):
            free_percent = (free_commit * 100.0) / total_total if total_total > 0 else 0.0
            if free_percent <= crit:
                s = "CRIT"
            elif free_percent <= warn:
                s = "WARN"
            else:
                s = "OK"
            state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
            metrics["commit_limit"] = free_commit
            metrics["mem_lnx_commit_limit_percent"] = free_percent
        else:
            # Fallback
            metrics["commit_limit"] = free_commit

    # VMalloc (largest free chunk)
    if vmalloc_total > 0 and vmalloc_chunk > 0:
        free_vmalloc = vmalloc_total - vmalloc_used if vmalloc_used > 0 else vmalloc_chunk
        typ, (warn, crit) = levels_vmalloc
        if typ.startswith("abs_free"):
            if free_vmalloc <= crit:
                s = "CRIT"
            elif free_vmalloc <= warn:
                s = "WARN"
            else:
                s = "OK"
            state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
            metrics["vmalloc_used"] = vmalloc_used
            metrics["vmalloc_chunk"] = vmalloc_chunk
            metrics["mem_lnx_vmalloc_free"] = free_vmalloc
        else:
            metrics["vmalloc_used"] = vmalloc_used
            metrics["vmalloc_chunk"] = vmalloc_chunk

    # Hardware corrupted
    if mem_total > 0 and hardware_corrupted >= 0:
        s, p = check_abs(hardware_corrupted, mem_total, levels_hardwarecorrupted)
        state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
        metrics["hardware_corrupted"] = hardware_corrupted

    # Pending/disk writeback
    if mem_total > 0:
        s, p = check_percent(pending, mem_total, ("perc_used", (10.0, 20.0)))  # default writeback levels
        state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
        metrics["pending"] = pending

    # MemAvailable (if present) — convert to used
    if mem_available != None:
        available_used = mem_total - mem_available
        s, p = check_percent(available_used, mem_total, ("perc_used", (80.0, 90.0)))  # default available levels
        state_overall = "CRIT" if s == "CRIT" else ("WARN" if state_overall != "CRIT" and s == "WARN" else state_overall)
        metrics["mem_available"] = mem_available
        metrics["mem_used_no_buffers"] = available_used

    msg = ", ".join(msg_parts) if msg_parts else "Memory: no data"
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_overall,
            "metrics": metrics,
            "details": "",
        },
    }