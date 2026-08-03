# Checkmk check: cephosdbluefs_slow
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# This check monitors the Ceph BlueFS "slow" device (the slow/main device)
# of a single OSD. It reproduces the discovery + core threshold logic of
# the Checkmk `cephosdbluefs_slow` plugin.
#
# Data source (not Checkmk): on a host that runs Ceph OSDs, the BlueFS
# stats are exposed by `ceph daemon osd.<id> bluefs`. We use `ceph`
# itself as the probe for "Ceph is on this host". If `ceph` is absent
# (rc==127) or returns no OSDs, discovery returns an empty list and
# check mode reports UNKNOWN.

MIB = 1024.0 * 1024.0


def _ceph_present(ctx):
    res = ctx.run(["ceph", "--version"], mutates=False)
    return res.rc == 0


def _list_osds(ctx):
    res = ctx.run(["ceph", "osd", "ls"], mutates=False)
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.split("\n"):
        s = line.strip()
        if s == "" or (s.lstrip("-").isdigit() == False):
            continue
        out.append(int(s))
    return out


def _bluefs_for_osd(ctx, osdid):
    res = ctx.run(["ceph", "daemon", "osd." + str(osdid), "bluefs"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    return json.decode(res.stdout)


def _pick_slow_osd(ctx, osds):
    for oid in osds:
        data = _bluefs_for_osd(ctx, oid)
        if data == None:
            continue
        slow = data.get("slow")
        if slow == None:
            continue
        total = float(slow.get("total_bytes", 0)) / MIB
        if total > 0:
            return oid
    return None


def main(ctx, params):
    if params.get("_discover"):
        if not _ceph_present(ctx):
            return {"changed": False,
                    "msg": "ceph not installed on this host",
                    "data": {"discovery": []}}
        osds = _list_osds(ctx)
        out = []
        for osdid in osds:
            data = _bluefs_for_osd(ctx, osdid)
            if data == None:
                continue
            slow = data.get("slow")
            if slow == None:
                continue
            total = float(slow.get("total_bytes", 0)) / MIB
            if total > 0:
                out.append({"item": str(osdid),
                            "params": {"warn": 80, "crit": 90},
                            "metrics": ["used_percent"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if not _ceph_present(ctx):
        return {"changed": False,
                "msg": "ceph not installed on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    osdid = None
    if item != "" and (item.lstrip("-").isdigit()):
        osdid = int(item)
    else:
        osds = _list_osds(ctx)
        osdid = _pick_slow_osd(ctx, osds)

    if osdid == None:
        return {"changed": False,
                "msg": "no ceph slow bluefs device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = _bluefs_for_osd(ctx, osdid)
    if data == None:
        return {"changed": False,
                "msg": "could not read bluefs stats for osd.%d" % osdid,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    slow = data.get("slow")
    if slow == None:
        return {"changed": False,
                "msg": "osd.%d has no slow bluefs device" % osdid,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_mb = float(slow.get("total_bytes", 0)) / MIB
    used_mb = float(slow.get("used_bytes", 0)) / MIB
    if total_mb <= 0:
        return {"changed": False,
                "msg": "osd.%s slow device has no capacity" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    avail_mb = total_mb - used_mb
    used_percent = (used_mb / total_mb) * 100.0

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "osd.%s slow %d MB total, %d MB used (%f%%), %d MB free" % (
            item, total_mb, used_mb, used_percent, avail_mb),
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent},
            "details": "total=%dMB used=%dMB avail=%dMB" % (
                total_mb, used_mb, avail_mb),
        },
    }