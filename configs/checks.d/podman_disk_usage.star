def render_bytes(n):
    n = float(n)
    units = ["B", "kB", "MB", "GB", "TB", "PB"]
    i = 0
    while n >= 1024.0 and i < len(units) - 1:
        n = n / 1024.0
        i = i + 1
    if i == 0:
        return "%d %s" % (int(n), units[i])
    return "%f %s" % (n, units[i])

def check_levels(value, levels, label):
    state = "OK"
    if levels != None:
        warn = levels[0]
        crit = levels[1]
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    return state

def normalize_type(t):
    if t == "Images":
        return "images"
    elif t == "Containers":
        return "containers"
    elif t == "Local Volumes":
        return "volumes"
    else:
        return t.lower()

def parse_disk_usage(data):
    disk_usage = {}
    for entry in data:
        t = entry.get("Type", "")
        key = normalize_type(t)
        size_val = float(entry.get("Size", 0))
        reclaimable_val = float(entry.get("ReclaimableSize", 0))
        total_val = int(entry.get("Total", 1))
        active_val = int(entry.get("Active", 0))

        if key in disk_usage:
            existing = disk_usage[key]
            new_size = existing["size"] + size_val
            new_total = existing["total"] + total_val
            new_active = existing["active"] + active_val
            new_reclaimable = existing["reclaimable"]
            if reclaimable_val > 0 or (new_reclaimable != None and new_reclaimable > 0):
                base = 0.0
                if new_reclaimable != None:
                    base = new_reclaimable
                new_reclaimable = base + reclaimable_val
            else:
                new_reclaimable = None
            disk_usage[key] = {
                "size": new_size,
                "reclaimable": new_reclaimable,
                "total": new_total,
                "active": new_active,
            }
        else:
            if reclaimable_val > 0:
                rec = reclaimable_val
            else:
                rec = None
            disk_usage[key] = {
                "size": size_val,
                "reclaimable": rec,
                "total": total_val,
                "active": active_val,
            }
    return disk_usage

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["podman", "--version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "podman not installed", "data": {"discovery": []}}

        res = ctx.run(["podman", "system", "df", "-v", "--format", "json"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "podman system df failed", "data": {"discovery": []}}

        if res.stdout == "" or res.stdout == None:
            return {"changed": False, "msg": "no data from podman", "data": {"discovery": []}}

        data = json.decode(res.stdout)
        if type(data) != "list":
            return {"changed": False, "msg": "unexpected podman output", "data": {"discovery": []}}

        disk_usage = parse_disk_usage(data)

        discovery = []
        for key in sorted(disk_usage.keys()):
            du = disk_usage[key]
            metrics = ["podman_disk_usage_%s_total_size" % key]
            if du["reclaimable"] != None:
                metrics.append("podman_disk_usage_%s_reclaimable_size" % key)
            metrics.append("podman_disk_usage_%s_total_number" % key)
            metrics.append("podman_disk_usage_%s_active_number" % key)
            discovery.append({
                "item": key,
                "params": {
                    "size_upper": None,
                    "reclaimable_upper": None,
                    "total": None,
                    "active": None,
                },
                "metrics": metrics,
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    sizes_params = params.get(item, {})

    probe = ctx.run(["podman", "--version"], mutates=False)
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "podman not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "podman binary not found"},
        }

    res = ctx.run(["podman", "system", "df", "-v", "--format", "json"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "podman system df failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    if res.stdout == "" or res.stdout == None:
        return {
            "changed": False,
            "msg": "no data from podman",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "empty output"},
        }

    data = json.decode(res.stdout)
    if type(data) != "list":
        return {
            "changed": False,
            "msg": "unexpected output format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "podman output is not a list"},
        }

    disk_usage = parse_disk_usage(data)

    if item not in disk_usage:
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "item not found in podman output"},
        }

    du = disk_usage[item]
    found_size = du["size"]
    found_reclaimable = du["reclaimable"]
    found_total = du["total"]
    found_active = du["active"]

    size_upper = None
    reclaimable_upper = None
    total_levels = None
    active_levels = None

    if type(sizes_params) == "dict":
        size_upper = sizes_params.get("size_upper")
        reclaimable_upper = sizes_params.get("reclaimable_upper")
        total_levels = sizes_params.get("total")
        active_levels = sizes_params.get("active")

    size_state = check_levels(found_size, size_upper, "Size")
    metrics = {"podman_disk_usage_%s_total_size" % item: found_size}
    details_parts = ["Size: %s" % render_bytes(found_size)]

    overall_state = size_state

    if found_reclaimable != None:
        reclaim_state = check_levels(found_reclaimable, reclaimable_upper, "Reclaimable")
        if reclaim_state == "CRIT":
            overall_state = "CRIT"
        elif reclaim_state == "WARN" and overall_state == "OK":
            overall_state = "WARN"
        metrics["podman_disk_usage_%s_reclaimable_size" % item] = found_reclaimable
        details_parts.append("Reclaimable: %s" % render_bytes(found_reclaimable))

    total_state = check_levels(found_total, total_levels, "Total")
    if total_state == "CRIT":
        overall_state = "CRIT"
    elif total_state == "WARN" and overall_state == "OK":
        overall_state = "WARN"
    metrics["podman_disk_usage_%s_total_number" % item] = found_total
    details_parts.append("Total: %d" % found_total)

    active_state = check_levels(found_active, active_levels, "Active")
    if active_state == "CRIT":
        overall_state = "CRIT"
    elif active_state == "WARN" and overall_state == "OK":
        overall_state = "WARN"
    metrics["podman_disk_usage_%s_active_number" % item] = found_active
    details_parts.append("Active: %d" % found_active)

    details = "\n".join(details_parts)

    if overall_state == "CRIT":
        msg = "CRIT - " + details
    elif overall_state == "WARN":
        msg = "WARN - " + details
    else:
        msg = details

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": metrics,
            "details": details,
        },
    }