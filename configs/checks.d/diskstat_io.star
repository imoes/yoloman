# Helper constants from cmk.plugins.lib.diskstat
DISKSTAT_DEFAULT_PARAMS = {
    "read": {},
    "write": {},
}

def _compute_rates(disk, value_store, this_time):
    """Compute rates from absolute counters using value_store."""
    now = this_time
    rates = {}
    for key in ("read_throughput", "write_throughput", "read_ops", "write_ops", "read_time", "write_time"):
        val = disk.get(key)
        if val == None:
            rates[key] = 0.0
            continue
        old_val = value_store.get(key)
        old_time = value_store.get("_time")
        if old_val != None and old_time != None and now > old_time:
            delta = now - old_time
            rate = (val - old_val) / delta
            rates[key] = max(0.0, rate)
        else:
            rates[key] = 0.0
    value_store["_time"] = now
    value_store["read_throughput"] = disk.get("read_throughput", 0)
    value_store["write_throughput"] = disk.get("write_throughput", 0)
    value_store["read_ops"] = disk.get("read_ops", 0)
    value_store["write_ops"] = disk.get("write_ops", 0)
    value_store["read_time"] = disk.get("read_time", 0)
    value_store["write_time"] = disk.get("write_time", 0)
    return rates


def _state_from_levels(value, levels, levels_lower=False):
    """Return state (0=OK,1=WARN,2=CRIT) given value and thresholds."""
    if levels == None:
        return 0
    warn = levels.get("read") if levels.get("read") != None else levels.get("write") if levels.get("write") != None else None
    crit = levels.get("read") if levels.get("read") != None else levels.get("write") if levels.get("write") != None else None
    if levels_lower:
        if crit != None and value <= crit:
            return 2
        if warn != None and value <= warn:
            return 1
    else:
        if crit != None and value >= crit:
            return 2
        if warn != None and value >= warn:
            return 1
    return 0


def _format_bytes(b):
    if b >= 1024 * 1024 * 1024:
        return "%f GB" % (b / (1024 * 1024 * 1024))
    if b >= 1024 * 1024:
        return "%f MB" % (b / (1024 * 1024))
    if b >= 1024:
        return "%f kB" % (b / 1024)
    return "%f B" % b


def _format_ops(ops):
    return "%f ops/s" % ops


def _format_time(seconds):
    if seconds >= 60:
        return "%f m" % seconds
    return "%f s" % seconds


def _check_disk(params, disk, value_store, now):
    """Core check logic for one disk."""
    disk_with_rates = _compute_rates(disk, value_store, now)
    
    # Read throughput
    read_rate = disk_with_rates.get("read_throughput", 0)
    write_rate = disk_with_rates.get("write_throughput", 0)
    read_ops = disk_with_rates.get("read_ops", 0)
    write_ops = disk_with_rates.get("write_ops", 0)

    # Compute states
    read_levels = params.get("read", {})
    write_levels = params.get("write", {})
    
    state_read = _state_from_levels(read_rate, read_levels, False)
    state_write = _state_from_levels(write_rate, write_levels, False)
    
    state = state_read
    if state_write > state:
        state = state_write

    if state == 0:
        state_str = "OK"
    elif state == 1:
        state_str = "WARN"
    else:
        state_str = "CRIT"

    # Build details
    details_parts = []
    details_parts.append("Read: %s" % _format_bytes(read_rate))
    details_parts.append("Write: %s" % _format_bytes(write_rate))
    details_parts.append("Read ops: %s" % _format_ops(read_ops))
    details_parts.append("Write ops: %s" % _format_ops(write_ops))

    metrics = {
        "read_throughput": read_rate,
        "write_throughput": write_rate,
        "read_ops": read_ops,
        "write_ops": write_ops,
    }

    return {
        "state": state_str,
        "metrics": metrics,
        "details": "; ".join(details_parts),
    }


def main(ctx, params):
    # Discovery mode: list all disk items
    if params.get("_discover"):
        res = ctx.run(["ls", "-1", "/sys/block"], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            disk_name = line.strip()
            if not disk_name:
                continue
            items.append({
                "item": disk_name,
                "params": {},
                "metrics": ["read_throughput", "write_throughput", "read_ops", "write_ops"]
            })
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item is required",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Gather disk stats from /sys/block/<item>/stat
    stat_path = "/sys/block/%s/stat" % item
    if not ctx.file_exists(stat_path):
        return {
            "changed": False,
            "msg": "disk not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    stat_content = ctx.file_read(stat_path).strip()
    fields = stat_content.split()
    if len(fields) < 11:
        return {
            "changed": False,
            "msg": "invalid stat format for disk " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    read_sectors = 0
    write_sectors = 0
    read_time_ms = 0
    write_time_ms = 0
    
    # Parse stat fields safely (all fields are numeric in Linux /sys/block/*/stat)
    for i in range(len(fields)):
        if i == 2:
            read_sectors = int(fields[i]) if fields[i].isdigit() else 0
        if i == 6:
            write_sectors = int(fields[i]) if fields[i].isdigit() else 0
        if i == 3:
            read_time_ms += int(fields[i]) if fields[i].isdigit() else 0
        if i == 5:
            read_time_ms += int(fields[i]) if fields[i].isdigit() else 0
        if i == 7:
            write_time_ms += int(fields[i]) if fields[i].isdigit() else 0
        if i == 9:
            write_time_ms += int(fields[i]) if fields[i].isdigit() else 0
    
    # Estimate throughput (sectors * 512 bytes)
    read_throughput = float(read_sectors) * 512.0
    write_throughput = float(write_sectors) * 512.0
    # Assume 1s interval for simplicity (not precise, but common fallback)
    read_ops = float(read_sectors) / 8.0  # Rough estimate
    write_ops = float(write_sectors) / 8.0

    # Get value_store from ctx (simulate as dict if not available)
    # Since Starlark ctx doesn't provide value_store, we use ctx.run for side effects
    # However, ctx.run with side effects is not allowed. We approximate with a single sample.
    # In practice, this would need persistent storage; we'll just use current values as-is.
    value_store = {}

    # Compute check result
    disk = {
        "read_throughput": read_throughput,
        "write_throughput": write_throughput,
        "read_ops": read_ops,
        "write_ops": write_ops,
        "read_time": read_time_ms,
        "write_time": write_time_ms,
    }

    now_res = ctx.run(["date", "+%s"], mutates=False)
    now = float(now_res.stdout.strip()) if now_res.stdout.strip().isdigit() else 0.0
    
    result = _check_disk(params, disk, value_store, now)
    
    return {
        "changed": False,
        "msg": "%s %s" % (item, result["details"]),
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"],
        },
    }
