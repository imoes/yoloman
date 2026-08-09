# Translated Checkmk check mk.hitachi_hnas_volume_virtual -> read-only Starlark

# OIDs (from BLUEARC-SERVER-MIB / TITAN-MIB)
VOL_BASE = ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1"
VIRT_BASE = ".1.3.6.1.4.1.11096.6.2.1.2.1.2.1"
QUOTA_BASE = ".1.3.6.1.4.1.11096.6.2.1.2.1.7.1"

VOL_OID_STATUS = VOL_BASE + ".4"
VOL_OID_NAME = VOL_BASE + ".3"
VOL_OID_CAPACITY = VOL_BASE + ".5"
VOL_OID_FREE = VOL_BASE + ".6"
VOL_OID_EVS = VOL_BASE + ".7"
VIRT_OID_VID = VIRT_BASE + ".1"
VIRT_OID_NAME = VIRT_BASE + ".2"
QUOTA_OID_TYPE = QUOTA_BASE + ".3"
QUOTA_OID_USAGE = QUOTA_BASE + ".4"
QUOTA_OID_LIMIT = QUOTA_BASE + ".6"

STATUS_MAP = {
    "1": "unformatted",
    "2": "mounted",
    "3": "formatted",
    "4": "needsChecking",
}

STATE_MAP = {
    "mounted": "OK",
    "unformatted": "WARN",
    "formatted": "WARN",
    "needsChecking": "CRIT",
}

# FILESYSTEM_DEFAULT_PARAMS defaults from cmk.plugins.lib.df
DEFAULT_WARN_PCT = 90
DEFAULT_CRIT_PCT = 95
# These mirror FILESYSTEM_DEFAULT_PARAMS usage levels used by df_check_filesystem_list
DEFAULT_PARAMS = {
    "levels": {
        "used_pct": (DEFAULT_WARN_PCT, DEFAULT_CRIT_PCT),
    },
}


def _snmpget(ctx, community, host, oid):
    res = ctx.run(
        [
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, oid,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    # strip possible type prefix just in case
    if val == "":
        return None
    return val


def _snmpwalk(ctx, community, host, oid):
    res = ctx.run(
        [
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, oid,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        out.append((line[:sp], line[sp + 1:].strip()))
    return out


def _parse_int(s):
    if s == None or s == "":
        return None
    if not s.lstrip("-").isdigit():
        return None
    return int(s)


def _to_mb(bytes_str):
    b = _parse_int(bytes_str)
    if b == None:
        return None
    return float(b) / 1048576.0


def _walk_table(ctx, community, host, entries, col_oid):
    """Correlate a column walk with index -> value mapping."""
    rows = _snmpwalk(ctx, community, host, col_oid)
    out = {}
    for oid, val in rows:
        if not oid.startswith(col_oid + "."):
            continue
        idx = oid[len(col_oid) + 1:]
        out[idx] = val
    return out


def _gather_volumes(ctx, community, host):
    """Walk the volume table. Returns dict volume_name -> (status, size_mb, avail_mb, evs)."""
    sys_idx = _walk_table(ctx, community, host, {}, VOL_BASE + ".1")
    label = _walk_table(ctx, community, host, {}, VOL_OID_NAME)
    status = _walk_table(ctx, community, host, {}, VOL_OID_STATUS)
    cap = _walk_table(ctx, community, host, {}, VOL_OID_CAPACITY)
    free = _walk_table(ctx, community, host, {}, VOL_OID_FREE)
    evs = _walk_table(ctx, community, host, {}, VOL_OID_EVS)

    parsed = {}
    for idx in sys_idx:
        volume_id = sys_idx[idx]
        if volume_id == "":
            continue
        lbl = label.get(idx, "")
        status_id = status.get(idx, "")
        st = STATUS_MAP.get(status_id, "unidentified")
        size_mb = _to_mb(cap.get(idx))
        avail_mb = _to_mb(free.get(idx))
        evs_val = evs.get(idx, "")
        name = "%s %s" % (volume_id, lbl)
        parsed[name] = (st, size_mb, avail_mb, evs_val)
    return parsed


def _gather_virtual_volumes(ctx, community, host, map_label):
    """Walk virtual volume + quota tables. Returns dict vv_name -> (size_mb, avail_mb)."""
    # virtual volumes: span id col (1) is the index/phys volume id, name (2)
    span = _walk_table(ctx, community, host, {}, VIRT_OID_VID)
    vv_name = _walk_table(ctx, community, host, {}, VIRT_OID_NAME)

    def quota_oid_end(phys_id, oid_end):
        parts = oid_end.split(".")[1:] + ["0"]
        return ".".join([phys_id] + parts)

    parsed = {}
    map_quota_oid = {}
    for idx in span:
        phys_id = span[idx]
        vv_label = vv_name.get(idx, "")
        phys_label = map_label.get(phys_id, "")
        name = "%s on %s" % (vv_label, phys_label)
        parsed[name] = (None, None)
        ref = quota_oid_end(phys_id, idx)
        map_quota_oid[ref] = name

    # quota rows: type(3), usage(4), limit(6), OID end provides index
    qtype = _walk_table(ctx, community, host, {}, QUOTA_OID_TYPE)
    qusage = _walk_table(ctx, community, host, {}, QUOTA_OID_USAGE)
    qlimit = _walk_table(ctx, community, host, {}, QUOTA_OID_LIMIT)

    for oid, tval in qtype.items():
        if tval != "3":
            continue
        usage = qusage.get(oid)
        limit = qlimit.get(oid)
        if usage != None and limit != None:
            vol = map_quota_oid.get(oid, "")
            if vol == "":
                continue
            size_mb = _to_mb(limit)
            u = _to_mb(usage)
            if size_mb == None or u == None:
                continue
            parsed[vol] = (size_mb, size_mb - u)
        else:
            vol = map_quota_oid.get(oid, "")
            if vol != "":
                parsed[vol] = (None, None)
    return parsed


def _gather(ctx, community, host):
    sys_idx = _walk_table(ctx, community, host, {}, VOL_BASE + ".1")
    if sys_idx == {}:
        return None
    # also need the volume sysdrive index table (col 1) to map indices
    vol_sys = _walk_table(ctx, community, host, {}, VOL_BASE + ".1")
    if vol_sys == {}:
        return None
    vol_label = _walk_table(ctx, community, host, {}, VOL_OID_NAME)
    vol_status = _walk_table(ctx, community, host, {}, VOL_OID_STATUS)
    vol_cap = _walk_table(ctx, community, host, {}, VOL_OID_CAPACITY)
    vol_free = _walk_table(ctx, community, host, {}, VOL_OID_FREE)
    vol_evs = _walk_table(ctx, community, host, {}, VOL_OID_EVS)

    map_label = {}
    volumes = {}
    for idx in vol_sys:
        vid = vol_sys[idx]
        if vid == "":
            continue
        map_label[vid] = vol_label.get(idx, "")
        st = STATUS_MAP.get(vol_status.get(idx, ""), "unidentified")
        volumes["%s %s" % (vid, vol_label.get(idx, ""))] = (
            st,
            _to_mb(vol_cap.get(idx)),
            _to_mb(vol_free.get(idx)),
            vol_evs.get(idx, ""),
        )

    if volumes == {}:
        return None

    virt = _gather_virtual_volumes(ctx, community, host, map_label)
    return {"volumes": volumes, "virtual_volumes": virt}


def _df_state(used_pct, warn, crit):
    if used_pct == None:
        return "UNKNOWN"
    if used_pct >= crit:
        return "CRIT"
    if used_pct >= warn:
        return "WARN"
    return "OK"


def _df_details(size_mb, avail_mb, used_pct):
    size_str = "%f MB" % size_mb if size_mb != None else "unknown"
    avail_str = "%f MB" % avail_mb if avail_mb != None else "unknown"
    pct_str = "%f%%" % used_pct if used_pct != None else "unknown"
    return "Size: %s, Avail: %s, Used: %s" % (size_str, avail_str, pct_str)


def main(ctx, params):
    if params.get("_discover"):
        # discovery: probe for the real device - snmpwalk on volume sys index
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        sys_walk = _walk_table(ctx, community, host, {}, VOL_BASE + ".1")
        if sys_walk == {}:
            return {"changed": False, "msg": "no Hitachi HNAS volumes found",
                    "data": {"discovery": []}}
        data = _gather(ctx, community, host)
        if data == None:
            return {"changed": False, "msg": "no Hitachi HNAS volumes found",
                    "data": {"discovery": []}}

        out = []
        for vname in data["volumes"]:
            out.append({"item": vname, "params": dict(DEFAULT_PARAMS),
                        "metrics": ["used_pct", "size_mb", "avail_mb"]})
        for vname in data["virtual_volumes"]:
            out.append({"item": vname, "params": dict(DEFAULT_PARAMS),
                        "metrics": ["used_pct", "size_mb", "avail_mb"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    data = _gather(ctx, community, host)
    if data == None:
        return {"changed": False, "msg": "no Hitachi HNAS volumes found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    is_virtual = item in data["virtual_volumes"]
    if not is_virtual and item not in data["volumes"]:
        return {"changed": False, "msg": "no such volume: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", {})
    used_levels = levels.get("used_pct", (DEFAULT_WARN_PCT, DEFAULT_CRIT_PCT))
    warn = used_levels[0] if used_levels != None else DEFAULT_WARN_PCT
    crit = used_levels[1] if used_levels != None else DEFAULT_CRIT_PCT

    metrics = {}
    if is_virtual:
        size_mb, avail_mb = data["virtual_volumes"][item]
        if size_mb == None or avail_mb == None:
            msg = "%s: no quota size information" % item
            return {"changed": False, "msg": msg,
                    "data": {"state": "OK", "metrics": metrics, "details": ""}}
        used_mb = size_mb - avail_mb
        used_pct = (used_mb / size_mb) * 100.0 if size_mb > 0 else None
        metrics = {"size_mb": size_mb, "avail_mb": avail_mb, "used_pct": used_pct}
        details = _df_details(size_mb, avail_mb, used_pct)
        state = _df_state(used_pct, warn, crit)
        return {"changed": False,
                "msg": "%s %s" % (item, details),
                "data": {"state": state, "metrics": metrics, "details": details}}

    status, size_mb, avail_mb, evs = data["volumes"][item]
    if status == "unidentified":
        return {"changed": False,
                "msg": "%s: Volume reports unidentified status" % item,
                "data": {"state": "CRIT", "metrics": {},
                         "details": "assigned to EVS %s" % evs}}

    used_mb = size_mb - avail_mb if (size_mb != None and avail_mb != None) else None
    used_pct = (used_mb / size_mb) * 100.0 if (used_mb != None and size_mb != None and size_mb > 0) else None
    metrics = {"size_mb": size_mb, "avail_mb": avail_mb, "used_pct": used_pct}
    details = _df_details(size_mb, avail_mb, used_pct)

    df_state = _df_state(used_pct, warn, crit)
    status_state = STATE_MAP.get(status, "OK")
    # status_state takes precedence as WARN/CRIT per STATE_MAP
    if status_state == "CRIT":
        state = "CRIT"
    elif status_state == "WARN":
        state = "WARN" if (df_state == "OK" or df_state == "UNKNOWN") else df_state
    else:
        state = df_state

    msg = "%s: Status: %s, %s" % (item, status, details)
    summary = "%s: Status: %s" % (item, status)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": details}}