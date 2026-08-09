def main(ctx, params):
    # Default filesystem thresholds (Checkmk FILESYSTEM_DEFAULT_PARAMS equivalent)
    fs_params = {
        "usage_on_disk": params.get("usage_on_disk", (80, 90)),
        "num_inodes": params.get("num_inodes", None),
        "size": params.get("size", None),
        "growth": params.get("growth", None),
    }
    usage_levels = fs_params["usage_on_disk"]
    warn = usage_levels[0]
    crit = usage_levels[1]

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.2.1.25.2.3.1"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no SNMP data", "data": {"discovery": []}}

        # Collect hrStorageType, hrStorageDescr, hrStorageAllocationUnits,
        # hrStorageSize, hrStorageUsed per index
        descr_by_idx = {}
        type_by_idx = {}
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 2:
                continue
            oid = f[0]
            val = f[1]
            idx = oid.rsplit(".", 1)[-1]
            suffix = oid[len(".1.3.6.1.2.1.25.2.3.1") + 1:]
            if suffix == "2":
                type_by_idx[idx] = val
            elif suffix == "3":
                descr_by_idx[idx] = val

        out = []
        for idx, hrtype in type_by_idx.items():
            if hrtype != ".1.3.6.1.2.1.25.2.1.4" and hrtype != ".1.3.6.1.2.1.25.2.3.1.2.4":
                continue
            descr = descr_by_idx.get(idx, "")
            if descr == "":
                continue
            if descr.startswith("/"):
                out.append({"item": descr, "params": {"usage_on_disk": (80, 90)},
                            "metrics": ["usage_on_disk"]})
        return {"changed": False, "msg": "discovered %d filesystems" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")

    # Fetch all five columns for this table via snmpwalk -Oqn on the base OID
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"), ".1.3.6.1.2.1.25.2.3.1"],
        mutates=False,
    )
    if walk.rc != 0:
        return {"changed": False, "msg": "no SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    descr_by_idx = {}
    type_by_idx = {}
    units_by_idx = {}
    size_by_idx = {}
    used_by_idx = {}
    for line in walk.stdout.splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        oid = f[0]
        val = f[1]
        idx = oid.rsplit(".", 1)[-1]
        suffix = oid[len(".1.3.6.1.2.1.25.2.3.1") + 1:]
        if suffix == "2":
            type_by_idx[idx] = val
        elif suffix == "3":
            descr_by_idx[idx] = val
        elif suffix == "4":
            units_by_idx[idx] = val
        elif suffix == "5":
            size_by_idx[idx] = val
        elif suffix == "6":
            used_by_idx[idx] = val

    # Find the index matching the requested item (mount point)
    target_idx = None
    for idx, descr in descr_by_idx.items():
        mp = fix_hr_fs_mountpoint(descr)
        if mp == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False, "msg": "no such filesystem: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    hrtype = type_by_idx.get(target_idx, "")
    if hrtype != ".1.3.6.1.2.1.25.2.1.4" and hrtype != ".1.3.6.1.2.1.25.2.3.1.2.4":
        return {"changed": False, "msg": "not a fixed disk: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    units = units_by_idx.get(target_idx, "1")
    size_raw = size_by_idx.get(target_idx, "0")
    used_raw = used_by_idx.get(target_idx, "0")

    unit_size = int(units) if units.isdigit() else 1
    size_mb = to_mb(size_raw, unit_size)
    used_mb = to_mb(used_raw, unit_size)
    avail_mb = size_mb - used_mb

    if size_mb <= 0:
        return {"changed": False, "msg": "filesystem size is zero: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    used_pct = (used_mb / size_mb) * 100.0
    state = "CRIT" if used_pct >= crit else ("WARN" if used_pct >= warn else "OK")

    if avail_mb < 0:
        avail_mb = 0

    return {
        "changed": False,
        "msg": "%s %f MB of %f MB (%f%%) used" % (item, used_mb, size_mb, used_pct),
        "data": {
            "state": state,
            "metrics": {"used_percent": used_pct, "used": used_mb, "size": size_mb},
            "details": "",
        },
    }


def fix_hr_fs_mountpoint(mp):
    mp = mp.replace("\\", "/")
    pos = mp.find("mounted on:")
    if pos != -1:
        return mp.rsplit(":", 1)[-1].strip()
    pos = mp.find("Label:")
    if pos != -1:
        return mp[:pos].rstrip()
    return mp


def to_mb(raw, unit_size):
    unscaled = int(raw) if raw.lstrip("-").isdigit() else 0
    if unscaled < 0:
        unscaled = unscaled + 4294967296
    return unscaled * unit_size / 1048576.0