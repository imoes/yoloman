def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

MEGA = 1048576.0

def _discover(ctx, params):
    mounts = _enumerate_nfsmounts(ctx)
    discovery = []
    for mp in sorted(mounts.keys()):
        entry = {"item": mp}
        entry["params"] = {}
        entry["metrics"] = ["fs_used", "fs_used_percent", "fs_free", "fs_size"]
        discovery.append(entry)
    msg = "discovered %d items" % len(discovery)
    return {"changed": False, "msg": msg, "data": {"discovery": discovery}}

def _check(ctx, params):
    item = params.get("item", "")
    mounts = _enumerate_nfsmounts(ctx)
    if item not in mounts:
        msg = "no such NFS mount: " + item
        return {"changed": False, "msg": msg, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mount = mounts[item]

    state = _classify_state(mount["state"])
    if state != "OK":
        level = _state_to_level(state)
        label = state.replace("_", " ").capitalize()
        msg = "State: %s" % label
        return {"changed": False, "msg": msg, "data": {"state": level, "metrics": {}, "details": ""}}

    if mount["mount_seems_okay"]:
        return {"changed": False, "msg": "Mount seems OK", "data": {"state": "OK", "metrics": {}, "details": ""}}

    if not mount["usage"]:
        return {"changed": False, "msg": "Mount seems OK", "data": {"state": "OK", "metrics": {}, "details": ""}}

    usage = mount["usage"]
    total_blocks = usage["total_blocks"]
    free_blocks = usage["free_blocks"]
    blocksize = usage["blocksize"]

    stale = total_blocks <= 0
    neg_free = free_blocks < 0
    big_bs = blocksize > int(16.0 * MEGA)
    if stale or neg_free or big_bs:
        return {"changed": False, "msg": "Stale fs handle", "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    to_mb = blocksize / MEGA
    size_mb = total_blocks * to_mb
    free_mb = free_blocks * to_mb
    used_mb = size_mb - free_mb
    used_percent = 0.0
    if size_mb > 0.0:
        used_percent = (used_mb / size_mb) * 100.0

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    if used_percent >= crit:
        level = "CRIT"
    elif used_percent >= warn:
        level = "WARN"
    else:
        level = "OK"

    metrics = {}
    metrics["fs_used"] = int(used_mb)
    metrics["fs_used_percent"] = int(used_percent)
    metrics["fs_free"] = int(free_mb)
    metrics["fs_size"] = int(size_mb)

    msg = "%s %d%% used" % (item, int(used_percent))
    return {"changed": False, "msg": msg, "data": {"state": level, "metrics": metrics, "details": ""}}

def _classify_state(state):
    sl = state.lower()
    if "permission denied" in sl:
        return "PERMISSION_DENIED"
    if "hanging" in sl:
        return "HANGING"
    if sl == "ok" or state in ("-", "--", "0"):
        return "OK"
    return "UNKNOWN"

def _state_to_level(state):
    if state in ("PERMISSION_DENIED", "HANGING", "UNKNOWN"):
        return "CRIT"
    return "OK"

def _enumerate_nfsmounts(ctx):
    mounts = {}
    res = ctx.run(["mount"], mutates=False)
    if res.rc == 0:
        for line in res.stdout.splitlines():
            cols = line.split()
            if len(cols) >= 4 and _is_nfs_type(cols[2]):
                src = cols[0]
                mp = cols[2]
                entry = {"mountpoint": mp}
                entry["state"] = "ok"
                entry["mount_seems_okay"] = True
                entry["usage"] = None
                entry["source"] = src
                mounts[mp] = entry
    return mounts

def _is_nfs_type(typ):
    t = typ.lower()
    nfs = t.startswith("nfs")
    nfs4 = t.startswith("nfs4")
    cifs = t.startswith("cifs")
    smbfs = t.startswith("smbfs")
    return nfs or nfs4 or cifs or smbfs