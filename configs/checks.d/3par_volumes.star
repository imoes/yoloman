# 3par_volumes — translated Checkmk check (read-only)
STATES = {1: "OK", 2: "WARN", 3: "CRIT"}
PROVISIONING_MAP = {1: "FULL", 2: "TPVV", 3: "SNP", 4: "PEER", 5: "UNKNOWN", 6: "TDVV", 7: "DDS"}

def _to_int(s):
    d = s.strip()
    if d.isdigit() or (d.startswith("-") and d[1:].isdigit()):
        return int(d)
    return None

def _to_float(s):
    d = s.strip()
    if d.replace(".", "", 1).replace("-", "", 1).isdigit():
        return float(d)
    return None

def _show_volumes(ctx):
    res = ctx.run(["3par", "showvv", "-d", "-f", "-space", "-tpvv", "-dedup", "-compaction", "-state", "-wwn"], mutates=False)
    if res.rc == 127:
        return None
    volumes = []
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 11:
            continue
        if not f[2].isdigit() or not f[3].isdigit() or not f[4].isdigit():
            continue
        volumes.append({"name": f[0], "is_system": f[1] == "1", "total": float(f[2]), "used": float(f[3]), "free": float(f[4]), "prov_type": PROVISIONING_MAP.get(_to_int(f[5]), "UNKNOWN"), "dedup": _to_float(f[6]), "compaction": _to_float(f[7]), "state": STATES.get(_to_int(f[8]), "UNKNOWN"), "wwn": f[9]})
    return volumes

def main(ctx, params):
    volumes = _show_volumes(ctx)
    if params.get("_discover"):
        if volumes == None:
            return {"changed": False, "msg": "3par CLI not found", "data": {"discovery": []}}
        discovery = []
        for v in volumes:
            if v["is_system"]:
                continue
            discovery.append({"item": v["name"], "params": {"levels": params.get("levels", (80.0, 90.0))}, "metrics": ["fs_provisioning", "used_percent"]})
        return {"changed": False, "msg": "discovered %d volumes" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    if volumes == None:
        return {"changed": False, "msg": "3par CLI not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vol = None
    for v in volumes:
        if v["name"] == item:
            vol = v
            break
    if vol == None:
        return {"changed": False, "msg": "no such volume: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if vol["total"] > 0:
        used_pct = (vol["total"] - vol["free"]) / vol["total"] * 100.0
    else:
        used_pct = 0.0
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if levels and len(levels) >= 1 else 80.0
    crit = levels[1] if levels and len(levels) >= 2 else 90.0
    state = "OK"
    if (used_pct >= crit):
        state = "CRIT"
    elif (used_pct >= warn):
        state = "WARN"
    metrics = {"fs_provisioning": vol["used"], "used_percent": used_pct}
    parts = ["Type: %s, WWN: %s" % (vol["prov_type"], vol["wwn"])]
    if vol["dedup"] != None:
        parts.append("Dedup: %s" % vol["dedup"])
    if vol["compaction"] != None:
        parts.append("Compact: %s" % vol["compaction"])
    parts.append("Used: %d%%" % used_pct)
    return {"changed": False, "msg": ", ".join(parts), "data": {"state": state, "metrics": metrics, "details": ", ".join(parts)}}