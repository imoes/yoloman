DISK_ITEMS = {
    "vdisk_": "VDisks",
    "mdisk_": "MDisks",
    "drive_": "Drives",
}

def _safe_float(s):
    if s == "" or s == None:
        return 0.0
    start = 0
    if len(s) > 0 and s[0] == "-":
        start = 1
    if start == len(s):
        return 0.0
    dot_seen = False
    valid = True
    for i in range(start, len(s)):
        c = s[i]
        if c == "." and not dot_seen:
            dot_seen = True
        elif c >= "0" and c <= "9":
            pass
        else:
            valid = False
    if not valid:
        return 0.0
    return float(s)

def _parse_stats(stdout):
    disks = {}
    for line in stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        stat_name = parts[0]
        if stat_name == "stat_name":
            continue
        stat_current = parts[1]
        for prefix, item_name in DISK_ITEMS.items():
            if stat_name.startswith(prefix):
                short = stat_name[len(prefix):]
                if item_name not in disks:
                    disks[item_name] = {}
                disks[item_name][short] = _safe_float(stat_current)
    return disks

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "admin")

    cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "%s@%s" % (username, host),
        "lssystemstats",
    ]
    res = ctx.run(cmd, mutates=False)

    if params.get("_discover"):
        if res.rc != 0:
            return {"changed": False, "msg": "no data from " + host,
                    "data": {"discovery": []}}
        disks = _parse_stats(res.stdout)
        out = [
            {"item": item, "params": {}, "metrics": ["read", "write"]}
            for item in sorted(disks.keys())
        ]
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    if res.rc != 0:
        return {"changed": False, "msg": "lssystemstats failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr}}

    disks = _parse_stats(res.stdout)
    item = params.get("item", "")

    if item not in disks:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    r_mb = disks[item].get("r_mb", 0.0)
    w_mb = disks[item].get("w_mb", 0.0)

    read_bytes = r_mb * 1024.0 * 1024.0
    write_bytes = w_mb * 1024.0 * 1024.0

    msg = "%f MB/s read, %f MB/s write" % (r_mb, w_mb)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": {"read": read_bytes, "write": write_bytes},
            "details": "",
        },
    }