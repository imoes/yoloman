BYTES_IN_GB = 1073741824.0

def _safe_int(v):
    if v == None:
        return 0
    s = str(v).strip()
    return int(s) if s.isdigit() else 0

def _safe_float(v):
    if v == None:
        return 0.0
    s = str(v).strip()
    if not s:
        return 0.0
    neg = s.startswith("-")
    check = s[1:] if neg else s
    nodot = check.replace(".", "", 1)
    if nodot and nodot.isdigit():
        return float(s)
    return 0.0

def _fetch_json(ctx, url, username, password):
    res = ctx.run(
        ["curl", "-sk", "-u", "%s:%s" % (username, password),
         "-H", "Accept: application/json",
         "--max-time", "30", url],
        mutates=False,
    )
    if res.rc != 0:
        return None
    stdout = res.stdout.strip()
    if not stdout:
        return None
    if not (stdout.startswith("{") or stdout.startswith("[")):
        return None
    return json.decode(stdout)

def _extract_sets(data):
    sets = {}
    if type(data) != "dict":
        return sets
    if "servicesets" not in data:
        return sets
    container = data["servicesets"]
    if type(container) != "dict" or "serviceset" not in container:
        return sets
    raw = container["serviceset"]
    items = raw if type(raw) == "list" else [raw]
    for entry in items:
        if type(entry) != "dict":
            continue
        merged = {}
        for k in entry:
            v = entry[k]
            if type(v) == "dict":
                for sk in v:
                    merged[sk] = v[sk]
            else:
                merged[k] = v
        sid = str(merged.get("id", str(len(sets) + 1)))
        sets[sid] = merged
    return sets

def _capacity_from_props(props):
    if "combinedCapacityBytes" in props:
        return (
            _safe_int(props.get("combinedCapacityBytes")),
            _safe_int(props.get("combinedFreeBytes")),
            _safe_int(props.get("combinedDiskBytes")),
            _safe_int(props.get("combinedUserBytes")),
        )
    if "localCapacityBytes" in props:
        return (
            _safe_int(props.get("localCapacityBytes")),
            _safe_int(props.get("localFreeBytes")),
            _safe_int(props.get("localDiskBytes")),
            _safe_int(props.get("localUserBytes")),
        )
    if "capacityBytes" in props:
        return (
            _safe_int(props.get("capacityBytes")),
            _safe_int(props.get("freeBytes")),
            _safe_int(props.get("diskBytes", 0)),
            _safe_int(props.get("userBytes", 0)),
        )
    return (0, 0, 0, 0)

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "Admin")
    password = params.get("password", "")
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)
    item = params.get("item", "")

    url = "https://%s/storeonceservices/cluster/servicesets/" % host
    data = _fetch_json(ctx, url, username, password)

    if params.get("_discover"):
        if data == None:
            return {
                "changed": False,
                "msg": "discovery failed: API unreachable on %s" % host,
                "data": {"discovery": []},
            }
        sets = _extract_sets(data)
        disc = [
            {
                "item": sid,
                "params": {"warn": 80.0, "crit": 90.0},
                "metrics": ["used_percent", "capacity_gb", "free_gb", "dedup_ratio"],
            }
            for sid in sets
        ]
        return {
            "changed": False,
            "msg": "discovered %d servicesets" % len(disc),
            "data": {"discovery": disc},
        }

    if data == None:
        return {
            "changed": False,
            "msg": "API unreachable: %s" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sets = _extract_sets(data)
    if item not in sets:
        return {
            "changed": False,
            "msg": "ServiceSet %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    props = sets[item]
    total, free, disk, user = _capacity_from_props(props)

    if total == 0:
        return {
            "changed": False,
            "msg": "no capacity data for ServiceSet %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used = total - free
    used_pct = (float(used) * 100.0) / float(total)
    total_gb = float(total) / BYTES_IN_GB
    free_gb = float(free) / BYTES_IN_GB
    used_gb = float(used) / BYTES_IN_GB

    dedup = 0.0
    if "dedupRatio" in props:
        dedup = _safe_float(props.get("dedupRatio"))
    elif "Deduplication Ratio" in props:
        dedup = _safe_float(props.get("Deduplication Ratio"))
    elif disk > 0:
        dedup = float(user) / float(disk)

    state = "CRIT" if used_pct >= crit else ("WARN" if used_pct >= warn else "OK")

    msg = "%f%% used (%f of %f GB), Dedup: %f:1" % (
        used_pct, used_gb, total_gb, dedup,
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_pct,
                "capacity_gb": total_gb,
                "free_gb": free_gb,
                "used_gb": used_gb,
                "dedup_ratio": dedup,
            },
            "details": "",
        },
    }