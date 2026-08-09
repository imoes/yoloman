def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["hp_msa_cli", "show", "volumes"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no hp_msa storage system reachable", "data": {"discovery": []}}
        parsed = _parse_volume_section(res.stdout)
        discovery = []
        for volume_name in sorted(parsed.keys()):
            entry = parsed[volume_name]
            discovery.append({"item": volume_name, "params": FILESYSTEM_DEFAULT_PARAMS, "metrics": ["size", "used", "free", "percent"]})
        return {"changed": False, "msg": "discovered %d volumes" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["hp_msa_cli", "show", "volumes"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no hp_msa storage system reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = _parse_volume_section(res.stdout)
    if item not in parsed:
        return {"changed": False, "msg": "volume not found: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    entry = parsed[item]
    size_mb = (int(entry.get("total-size-numeric", 0)) * 512) // (1024 * 1024)
    alloc_mb = (int(entry.get("allocated-size-numeric", 0)) * 512) // (1024 * 1024)
    used_mb = alloc_mb
    avail_mb = size_mb - alloc_mb
    warn = params.get("warn")
    crit = params.get("crit")
    used_percent = 0.0
    state = "OK"
    if size_mb > 0:
        used_percent = (used_mb / size_mb) * 100.0
        if warn != None and crit != None:
            if used_percent >= crit:
                state = "CRIT"
            elif used_percent >= warn:
                state = "WARN"
    msg = "%s (%s)" % (entry.get("virtual-disk-name", item), entry.get("raidtype", "unknown"))
    details = "Size: %d MB, Used: %d MB, Avail: %d MB (%f%%)" % (size_mb, used_mb, avail_mb, used_percent)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"size": size_mb, "used": used_mb, "free": avail_mb, "percent": used_percent}, "details": details}}


FILESYSTEM_DEFAULT_PARAMS = {"warn": 80, "crit": 90}


def _parse_volume_section(stdout):
    pre_parsed = {}
    for line in stdout.splitlines():
        f = line.split()
        if len(f) < 4:
            continue
        item_type = f[0]
        numerical_id = f[1]
        key = f[2]
        value = " ".join(f[3:])
        sub = pre_parsed.get(numerical_id, {})
        if key not in sub:
            sub[key] = value
        if key == "durable-id":
            sub["item_type"] = item_type
        pre_parsed[numerical_id] = sub
    parsed = {}
    for v in pre_parsed.values():
        volume_name = v.get("volume-name")
        if volume_name != None and volume_name not in parsed:
            parsed[volume_name] = v
    return parsed