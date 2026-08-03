def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


_MAP_STATES = {
    "1": ("UNKNOWN", "other"),
    "2": ("OK", "OK"),
    "3": ("CRIT", "failed"),
    "4": ("WARN", "unconfigured"),
    "5": ("WARN", "recovering"),
    "6": ("WARN", "ready for rebuild"),
    "7": ("WARN", "rebuilding"),
    "8": ("CRIT", "wrong drive"),
    "9": ("CRIT", "bad connect"),
    "10": ("CRIT", "overheating"),
    "11": ("WARN", "shutdown"),
    "12": ("WARN", "automatic data expansion"),
    "13": ("CRIT", "not available"),
    "14": ("WARN", "queued for expansion"),
    "15": ("WARN", "multi-path access degraded"),
    "16": ("WARN", "erasing"),
}

_BASE = ".1.3.6.1.4.1.232.3.2.3.1.1"
_COL_2 = ".2"
_COL_4 = ".4"
_COL_9 = ".9"
_COL_12 = ".12"
_COL_14 = ".14"
_PRODUCT_OID = ".1.3.6.1.4.1.232.2.2.4.2.0"


def _sanitize_item(item):
    return item.replace("\x00", "\\x00")


def _probe_present(ctx, params):
    res = ctx.run(
        ["snmpget", "-v", "2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), _PRODUCT_OID],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0:
        return False
    val = res.stdout.strip()
    if val == "":
        return False
    low = val.lower()
    return low.find("proliant") != -1 or low.find("storeeasy") != -1 or low.find("synergy") != -1


def _walk_col(ctx, params, col):
    return ctx.run(
        ["snmpwalk", "-v", "2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"), _BASE + col],
        mutates=False,
    )


def _get_col(ctx, params, col, idx):
    r = ctx.run(
        ["snmpget", "-v", "2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), _BASE + col + "." + idx],
        mutates=False,
    )
    if r.rc != 0:
        return ""
    return r.stdout.strip()


def _parse_idx(line, col):
    sp = line.find(" ")
    if sp == -1:
        return ""
    oid = line[:sp]
    col_base = _BASE + col
    if not oid.startswith(col_base + "."):
        return ""
    return oid[len(col_base) + 1:]


def _to_int(s):
    if s == "":
        return 0
    if s.lstrip("-").isdigit():
        return int(s)
    return 0


def _human_bytes(n):
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    i = 0
    v = float(n)
    while v >= 1024 and i < len(units) - 1:
        v = v / 1024.0
        i = i + 1
    if i == 0:
        return "%d %s" % (n, units[i])
    return "%f %s" % (v, units[i])


def _discover(ctx, params):
    if not _probe_present(ctx, params):
        return {"changed": False, "msg": "not a ProLiant/StoreEasy/Synergy system",
                "data": {"discovery": []}}

    res = _walk_col(ctx, params, _COL_2)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "no hp_proliant_raid devices found",
                "data": {"discovery": []}}

    names = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        idx = oid[len(_BASE + _COL_2) + 1:]
        if idx == "":
            continue
        names[idx] = value

    out = []
    for idx, name in sorted(names.items()):
        item = _sanitize_item((name + " " + idx).strip())
        out.append({"item": item, "params": {}, "metrics": ["rebuild_percent"]})
    return {"changed": False, "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}}


def _check(ctx, params):
    if not _probe_present(ctx, params):
        return {"changed": False, "msg": "device is not a ProLiant/StoreEasy/Synergy system",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")

    res_walk = _walk_col(ctx, params, _COL_2)
    if res_walk.rc != 0 or res_walk.stdout == "":
        return {"changed": False, "msg": "no hp_proliant_raid devices found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_idx = None
    name_val = ""
    for line in res_walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        idx = oid[len(_BASE + _COL_2) + 1:]
        if idx == "":
            continue
        if _sanitize_item((value + " " + idx).strip()) == item:
            target_idx = idx
            name_val = value
            break

    if target_idx == None:
        return {"changed": False, "msg": "no such logical device: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    number_name = _get_col(ctx, params, _COL_14, target_idx)
    status = _get_col(ctx, params, _COL_4, target_idx)
    size_str = _get_col(ctx, params, _COL_9, target_idx)
    rebuild = _get_col(ctx, params, _COL_12, target_idx)

    size_bytes = _to_int(size_str) * 1024 * 1024
    rebuild_percent = _to_int(rebuild)

    state, state_readable = _MAP_STATES.get(status, ("UNKNOWN", "unknown"))

    try_size = _human_bytes(size_bytes)
    details = "Status: " + state_readable + "\n"
    details = details + "Logical volume size: " + try_size + "\n"

    if status not in ("7", "12"):
        return {"changed": False,
                "msg": "Status: " + state_readable + ", Size: " + try_size,
                "data": {"state": state, "metrics": {"rebuild_percent": rebuild_percent},
                         "details": details.rstrip("\n")}}

    if rebuild_percent == 4294967295:
        detail_rebuild = "Rebuild: undetermined"
        msg_rebuild = "Rebuild: undetermined"
    else:
        pct = "%d%%" % rebuild_percent
        detail_rebuild = "Rebuild: " + pct
        msg_rebuild = "Rebuild: " + pct

    return {"changed": False,
            "msg": "Status: " + state_readable + ", Size: " + try_size + ", " + msg_rebuild,
            "data": {"state": state, "metrics": {"rebuild_percent": rebuild_percent},
                     "details": (details + detail_rebuild).rstrip("\n")}}