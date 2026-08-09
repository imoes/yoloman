def _parse_meminfo(content):
    out = {}
    for line in content.splitlines():
        parts = line.split(":")
        if len(parts) != 2:
            continue
        key = parts[0].strip()
        val_parts = parts[1].strip().split()
        if len(val_parts) == 0:
            continue
        num_str = val_parts[0]
        if not num_str.isdigit():
            continue
        out[key] = int(num_str)
    return out


def main(ctx, params):
    if params.get("_discover"):
        info = ctx.file_read("/proc/meminfo") if ctx.file_exists("/proc/meminfo") else ""
        if not info:
            return {"changed": False, "msg": "no /proc/meminfo",
                    "data": {"discovery": []}}
        mem = _parse_meminfo(info)
        if "VmallocTotal" not in mem:
            return {"changed": False, "msg": "no vmalloc info",
                    "data": {"discovery": []}}
        if mem.get("VmallocUsed", 0) == 0 and mem.get("VmallocChunk", 0) == 0:
            return {"changed": False, "msg": "vmalloc data zero",
                    "data": {"discovery": []}}
        if mem.get("VmallocTotal", 0) >= 4 * 1024 * 1024:
            return {"changed": False, "msg": "64-bit system, skipped",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"levels_used_perc": (80.0, 90.0),
                                "levels_lower_chunk_mb": (64, 32)},
                     "metrics": ["total_mb", "used_mb", "chunk_mb"]}]}}

    info = ctx.file_read("/proc/meminfo") if ctx.file_exists("/proc/meminfo") else ""
    if not info:
        return {"changed": False, "msg": "no /proc/meminfo",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    mem = _parse_meminfo(info)
    if "VmallocTotal" not in mem or "VmallocUsed" not in mem or "VmallocChunk" not in mem:
        return {"changed": False, "msg": "vmalloc fields missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_mb = mem["VmallocTotal"] / 1024.0 / 1024.0
    used_mb = mem["VmallocUsed"] / 1024.0 / 1024.0
    chunk_mb = mem["VmallocChunk"] / 1024.0 / 1024.0

    levels = params.get("levels_used_perc", (80.0, 90.0))
    warn_perc = levels[0]
    crit_perc = levels[1]
    warn_abs = total_mb * warn_perc / 100.0
    crit_abs = total_mb * crit_perc / 100.0

    if used_mb >= crit_abs:
        state = "CRIT"
    elif used_mb >= warn_abs:
        state = "WARN"
    else:
        state = "OK"

    lower = params.get("levels_lower_chunk_mb", (64, 32))
    chunk_warn = lower[0]
    chunk_crit = lower[1]
    if chunk_mb <= chunk_crit:
        chunk_state = "CRIT"
    elif chunk_mb <= chunk_warn:
        chunk_state = "WARN"
    else:
        chunk_state = "OK"

    final_state = "CRIT" if (state == "CRIT" or chunk_state == "CRIT") else (
        "WARN" if (state == "WARN" or chunk_state == "WARN") else "OK")

    msg = "Total: %f MB, Used: %f MB, Chunk: %f MB" % (total_mb, used_mb, chunk_mb)
    details = msg
    return {"changed": False, "msg": msg,
            "data": {"state": final_state,
                     "metrics": {"total_mb": total_mb, "used_mb": used_mb, "chunk_mb": chunk_mb},
                     "details": details}}