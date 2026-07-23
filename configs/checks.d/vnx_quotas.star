def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    
    return _check(ctx, params)


def _discover(ctx, params):
    res = ctx.run(["vnx_quotas"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to gather vnx_quotas data", "data": {"discovery": []}}
    
    if not res.stdout:
        return {"changed": False, "msg": "no vnx_quotas data available", "data": {"discovery": []}}
    
    section = _parse_vnx_quotas(res.stdout)
    
    dms_names = params.get("dms_names", [])
    mp_names = params.get("mp_names", [])
    
    out = []
    for quota in section.quotas:
        parts = quota.name.split(" ", 1)
        dms = parts[0] if len(parts) > 0 else ""
        mpt = parts[1] if len(parts) > 1 else ""
        
        dms = _rename(dms, dms_names)
        mpt = _rename(mpt, mp_names)
        
        item = dms + " " + mpt
        out.append({
            "item": item,
            "params": {"pattern": quota.name},
            "metrics": ["used_percent", "free", "used"]
        })
    
    return {"changed": False, "msg": "discovered %d quotas" % len(out), "data": {"discovery": out}}


def _check(ctx, params):
    item = params.get("item", "")
    
    res = ctx.run(["vnx_quotas"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "no vnx_quotas data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    section = _parse_vnx_quotas(res.stdout)
    quota = _get_quota(item, params, section)
    
    if quota == None:
        return {
            "changed": False,
            "msg": "quota not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    use_fs = (quota.limit == "0" or quota.limit == "NoLimit") and quota.fs in section.fs_sizes
    size_mb = float(section.fs_sizes[quota.fs]) / 1048576.0 if use_fs else (float(quota.limit) if quota.limit.isdigit() else 0.0) / 1024.0
    used_mb = float(quota.used) / 1048576.0
    free_mb = size_mb - used_mb
    
    levels = params.get("levels", [80.0, 90.0])
    if type(levels) != "list":
        levels = [80.0, 90.0]
    warn_percent = levels[0] if len(levels) >= 1 else 80.0
    crit_percent = levels[1] if len(levels) >= 2 else 90.0
    
    if size_mb > 0:
        used_percent = (used_mb / size_mb) * 100.0
    else:
        used_percent = 0.0
    
    if used_percent >= crit_percent:
        state = "CRIT"
    elif used_percent >= warn_percent:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Size: %f MB, Used: %f MB (%f%%), Free: %f MB" % (size_mb, used_mb, used_percent, free_mb)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "free": free_mb * 1048576.0,
                "used": used_mb * 1048576.0
            },
            "details": ""
        }
    }


def _parse_vnx_quotas(output):
    section = {"fs_sizes": {}, "quotas": []}
    subsection = None
    
    lines = output.split("\n")
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        
        if stripped.startswith("[[[") and stripped.endswith("]]]"):
            subsection = stripped[3:-3]
            continue
        
        if subsection == "fs":
            parts = stripped.split(",")
            if len(parts) >= 5:
                fs_name = parts[0].strip()
                fs_total_bytes = int(parts[4]) * 1024 if parts[4].isdigit() else 0
                section["fs_sizes"][fs_name] = fs_total_bytes
        
        elif subsection == "quotas":
            parts = stripped.split(",")
            if len(parts) == 5:
                dms = parts[0].strip()
                fs = parts[1].strip()
                mp = parts[2].strip()
                used_str = parts[3].strip()
                limit_str = parts[4].strip()
                
                name = dms + " " + mp
                used = int(used_str) * 1024 if used_str.isdigit() else 0
                
                section["quotas"].append({
                    "name": name,
                    "fs": fs,
                    "limit": limit_str,
                    "used": used
                })
    
    return section


def _get_quota(item, params, section):
    pattern = params.get("pattern", "")
    for quota in section.quotas:
        if quota["name"] == item or quota["name"] == pattern:
            return quota
    return None


def _rename(name, mappings):
    for mapping in mappings:
        if type(mapping) == "list" and len(mapping) == 2:
            match = mapping[0]
            substitution = mapping[1]
            
            if match.startswith("~"):
                if match.startswith("^") and match.endswith("$"):
                    pattern = match[1:-1]
                    if name == pattern:
                        return substitution
                elif match.startswith("^"):
                    pattern = match[1:]
                    if name.startswith(pattern):
                        return substitution
                elif match.endswith("$"):
                    pattern = match[:-1]
                    if name.endswith(pattern):
                        return substitution
            else:
                if name == match:
                    return substitution
    
    return name
