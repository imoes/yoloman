def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["hpssacli", "ctrl", "all", "show"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 volumes", "data": {"discovery": []}}

        res = ctx.run(["hpssacli", "ctrl", "all", "show", "config", "detail"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 volumes", "data": {"discovery": []}}

        out = []
        lines = res.stdout.splitlines()
        current_volume = {}
        for line in lines:
            line = line.strip()
            if not line:
                if "name" in current_volume:
                    out.append({"item": current_volume["name"], "params": {}, "metrics": ["used_percent"]})
                current_volume = {}
                continue

            idx = line.find(":")
            if idx != -1:
                key = line[:idx].strip().lower().replace(" ", "-")
                val = line[idx+1:].strip()
                current_volume[key] = val

        if "name" in current_volume:
            out.append({"item": current_volume["name"], "params": {}, "metrics": ["used_percent"]})

        return {"changed": False, "msg": "discovered %d volumes" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["hpssacli", "ctrl", "all", "show", "config", "detail"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "volume not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    current_volume = {}
    for line in lines:
        line = line.strip()
        if not line:
            if "name" in current_volume and current_volume["name"] == item:
                break
            current_volume = {}
            continue
        idx = line.find(":")
        if idx != -1:
            key = line[:idx].strip().lower().replace(" ", "-")
            val = line[idx+1:].strip()
            current_volume[key] = val

    if "name" not in current_volume or current_volume["name"] != item:
        return {"changed": False, "msg": "volume not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    virtual_disk_name = current_volume.get("virtual-disk-name", "")
    raidtype = current_volume.get("raid-type", "")

    total_str = current_volume.get("total-size", "")
    alloc_str = current_volume.get("allocated-size", "")

    def parse_size_to_sectors(s):
        s = s.strip()
        if not s:
            return 0
        num_part = ""
        unit_part = ""
        i = len(s) - 1
        while i >= 0:
            c = s[i]
            if c.isdigit() or c == '.':
                num_part = c + num_part
            else:
                unit_part = c + unit_part
            i = i - 1
        if not num_part:
            return 0
        num = float(num_part)
        unit = unit_part.strip().lower()
        if unit.startswith("kb"):
            return int(num * 1024 / 512)
        elif unit.startswith("mb"):
            return int(num * 1024 * 1024 / 512)
        elif unit.startswith("gb"):
            return int(num * 1024 * 1024 * 1024 / 512)
        elif unit.startswith("tb"):
            return int(num * 1024 * 1024 * 1024 * 1024 / 512)
        else:
            return int(num)
    
    total_size_numeric = parse_size_to_sectors(total_str) if total_str else 0
    allocated_size_numeric = parse_size_to_sectors(alloc_str) if alloc_str else 0

    size_mb = (total_size_numeric * 512) // (1024 * 1024)
    alloc_mb = (allocated_size_numeric * 512) // (1024 * 1024)
    avail_mb = size_mb - alloc_mb

    used_percent = (alloc_mb * 100) // size_mb if size_mb > 0 else 0

    summary = "%s (%s)" % (virtual_disk_name, raidtype)

    warn = params.get("levels", (80.0, 90.0))
    crit = params.get("levels", (90.0, 95.0))
    
    warn_percent = float(warn[0]) if len(warn) >= 1 else 80.0
    crit_percent = float(crit[0]) if len(crit) >= 1 else 90.0

    state = "OK"
    if used_percent >= crit_percent:
        state = "CRIT"
    elif used_percent >= warn_percent:
        state = "WARN"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "size": size_mb,
                "used": alloc_mb,
                "available": avail_mb
            },
            "details": ""
        }
    }