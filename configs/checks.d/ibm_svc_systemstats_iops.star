def _parse_systemstats(stdout):
    cpu_pc = None
    total_cache_pc = None
    write_cache_pc = None
    disks = {}

    for line in stdout.splitlines():
        f = line.split()
        if len(f) < 4:
            continue
        stat_name = f[0]
        stat_current = f[1]

        if stat_name == "cpu_pc":
            cpu_pc = int(stat_current)
        elif stat_name == "total_cache_pc":
            total_cache_pc = int(stat_current)
        elif stat_name == "write_cache_pc":
            write_cache_pc = int(stat_current)

        if stat_name.startswith("vdisk_"):
            short = stat_name[len("vdisk_"):]
            disks.setdefault("VDisks", {})[short] = float(stat_current)
        elif stat_name.startswith("mdisk_"):
            short = stat_name[len("mdisk_"):]
            disks.setdefault("MDisks", {})[short] = float(stat_current)
        elif stat_name.startswith("drive_"):
            short = stat_name[len("drive_"):]
            disks.setdefault("Drives", {})[short] = float(stat_current)

    return cpu_pc, total_cache_pc, write_cache_pc, disks


def _render_bytes(b):
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(b)
    idx = 0
    while value >= 1024.0 and idx < len(units) - 1:
        value = value / 1024.0
        idx = idx + 1
    s = "%f" % value
    if idx == 0:
        s = str(int(value))
    return s + " " + units[idx]


def _grade(value, warn, crit):
    if value == None or warn == None or crit == None:
        return "OK"
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["svcinfo", "lsioperf", "-nohdr", "-delim", " "], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no IBM SVC system found",
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "no IBM SVC system found",
                    "data": {"discovery": []}}
        cpu_pc, total_cache_pc, write_cache_pc, disks = _parse_systemstats(res.stdout)

        discovery = []
        for item in disks:
            discovery.append({"item": item, "params": {},
                              "metrics": ["read", "write"]})

        if cpu_pc != None:
            discovery.append({"item": "", "params": {},
                              "metrics": ["utilization"]})

        if total_cache_pc != None:
            discovery.append({"item": "", "params": {},
                              "metrics": ["write_cache_pc", "total_cache_pc"]})

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["svcinfo", "lsioperf", "-nohdr", "-delim", " "], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no IBM SVC system found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu_pc, total_cache_pc, write_cache_pc, disks = _parse_systemstats(res.stdout)

    if item not in disks:
        return {"changed": False,
                "msg": "item '" + item + "' not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats = disks[item]
    read_iops = stats.get("r_io", 0)
    write_iops = stats.get("w_io", 0)

    warn = params.get("warn", None)
    crit = params.get("crit", None)
    state = _grade(max(read_iops, write_iops), warn, crit)

    return {"changed": False,
            "msg": "%s IO/s read, %s IO/s write" % (read_iops, write_iops),
            "data": {"state": state,
                     "metrics": {"read": read_iops, "write": write_iops},
                     "details": ""}}