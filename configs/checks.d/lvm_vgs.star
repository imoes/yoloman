WARN_DEFAULT = 80.0
CRIT_DEFAULT = 90.0

def _to_int(s):
    s = s.strip()
    dot = s.find(".")
    if dot >= 0:
        s = s[:dot]
    if s.isdigit():
        return int(s)
    return -1

def _parse_vgs(stdout):
    result = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 7:
            continue
        name = parts[0]
        size = _to_int(parts[5])
        free = _to_int(parts[6])
        if size >= 0 and free >= 0:
            result.append({"name": name, "size": size, "free": free})
    return result

def main(ctx, params):
    res = ctx.run(
        ["vgs", "--noheadings", "--nosuffix", "--units", "b",
         "-o", "vg_name,pv_count,lv_count,snap_count,vg_attr,vg_size,vg_free"],
        mutates=False,
        ok_codes=[0, 5, 127],
    )

    if params.get("_discover"):
        if res.rc == 127:
            return {"changed": False, "msg": "vgs not installed",
                    "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "vgs exited with rc %d" % res.rc,
                    "data": {"discovery": []}}
        vgs = _parse_vgs(res.stdout)
        items = []
        for vg in vgs:
            items.append({
                "item": vg["name"],
                "params": {"warn": WARN_DEFAULT, "crit": CRIT_DEFAULT},
                "metrics": ["used_percent", "used_mb", "free_mb", "total_mb"],
            })
        return {"changed": False, "msg": "discovered %d volume groups" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")

    if res.rc == 127:
        return {"changed": False, "msg": "vgs not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "vgs exited with rc %d" % res.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vgs = _parse_vgs(res.stdout)
    found = None
    for vg in vgs:
        if vg["name"] == item:
            found = vg
            break

    if found == None:
        return {"changed": False, "msg": "VG %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    size_bytes = found["size"]
    free_bytes = found["free"]
    used_bytes = size_bytes - free_bytes

    if size_bytes == 0:
        return {"changed": False, "msg": "VG %s has zero size" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    used_percent = (float(used_bytes) / float(size_bytes)) * 100.0
    total_mb = size_bytes // (1024 * 1024)
    free_mb = free_bytes // (1024 * 1024)
    used_mb = total_mb - free_mb

    warn = params.get("warn", WARN_DEFAULT)
    crit = params.get("crit", CRIT_DEFAULT)

    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "VG %s: %f%% used (%d MiB of %d MiB, %d MiB free)" % (
        item, used_percent, used_mb, total_mb, free_mb)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "used_mb": float(used_mb),
                "free_mb": float(free_mb),
                "total_mb": float(total_mb),
            },
            "details": "",
        },
    }