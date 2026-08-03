# Disk IO check plugin translation: reads /proc/diskstats and grades per-disk I/O throughput

DISK_STAT_PATH = "/proc/diskstats"

def _parse_int(s):
    stripped = str(s)
    neg = False
    if stripped.startswith("-"):
        neg = True
        stripped = stripped[1:]
    if not stripped.isdigit():
        return 0
    val = int(stripped)
    if neg:
        val = -val
    return val

def _read_diskstats(ctx):
    content = ctx.file_read(DISK_STAT_PATH) if ctx.file_exists(DISK_STAT_PATH) else ""
    disks = {}
    for line in content.splitlines():
        f = line.split()
        if len(f) < 15:
            continue
        dev = f[2]
        if not dev:
            continue
        if dev.startswith("loop") or dev.startswith("ram"):
            continue
        disks[dev] = {
            "sectors_read": f[5],
            "sectors_written": f[9],
            "reads_completed": f[3],
            "writes_completed": f[7],
            "time_ios": f[12],
        }
    return disks

def _compute_rates(ctx, dev, disks):
    stats = disks[dev]
    sector_size = 512
    read_kb = _parse_int(stats["sectors_read"]) * sector_size / 1024.0
    write_kb = _parse_int(stats["sectors_written"]) * sector_size / 1024.0
    io_ticks = _parse_int(stats["time_ios"])
    util = 0.0
    return {
        "read_throughput": read_kb,
        "write_throughput": write_kb,
        "util": util,
    }

def _grade_value(value, warn, crit, direction):
    if warn == None and crit == None:
        return "OK"
    if direction == "upper":
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
        return "OK"
    else:
        if value <= crit:
            return "CRIT"
        if value <= warn:
            return "WARN"
        return "OK"

def _max_state(s1, s2):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(s1, 3) >= order.get(s2, 3):
        return s1
    return s2

def main(ctx, params):
    if params.get("_discover"):
        if not ctx.file_exists(DISK_STAT_PATH):
            return {
                "changed": False,
                "msg": "discovered 0 disk IO services",
                "data": {"discovery": []},
            }
        disks = _read_diskstats(ctx)
        discovery = []
        for dev in sorted(disks.keys()):
            discovery.append({
                "item": dev,
                "params": {},
                "metrics": ["read_throughput", "write_throughput", "util"],
            })
        return {
            "changed": False,
            "msg": "discovered %d disk IO services" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    if not ctx.file_exists(DISK_STAT_PATH):
        return {
            "changed": False,
            "msg": "no disk IO data available (/proc/diskstats missing)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    disks = _read_diskstats(ctx)

    if item == "SUMMARY":
        if not disks:
            return {
                "changed": False,
                "msg": "no disks to summarize",
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": "",
                },
            }
        total_read = 0
        total_write = 0
        max_util = 0
        for dev in disks:
            d = _compute_rates(ctx, dev, disks)
            total_read += d["read_throughput"]
            total_write += d["write_throughput"]
            max_util = max(max_util, d["util"])
        metrics = {
            "read_throughput": total_read,
            "write_throughput": total_write,
            "util": max_util,
        }
        return {
            "changed": False,
            "msg": "Summary IO: read %f KB/s, write %f KB/s, max util %f%%" % (total_read, total_write, max_util),
            "data": {
                "state": "OK",
                "metrics": metrics,
                "details": "",
            },
        }

    if item == "" or item not in disks:
        return {
            "changed": False,
            "msg": "no such disk: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    d = _compute_rates(ctx, item, disks)
    metrics = {
        "read_throughput": d["read_throughput"],
        "write_throughput": d["write_throughput"],
        "util": d["util"],
    }

    read_warn = None
    read_crit = None
    write_warn = None
    write_crit = None
    util_warn = None
    util_crit = None

    rt_params = params.get("read_throughput")
    if rt_params != None and type(rt_params) == "dict":
        read_warn = rt_params.get("warn", None)
        read_crit = rt_params.get("crit", None)

    wt_params = params.get("write_throughput")
    if wt_params != None and type(wt_params) == "dict":
        write_warn = wt_params.get("warn", None)
        write_crit = wt_params.get("crit", None)

    util_p = params.get("util")
    if util_p != None and type(util_p) == "dict":
        util_warn = util_p.get("warn", None)
        util_crit = util_p.get("crit", None)

    state = "OK"
    state = _max_state(state, _grade_value(d["read_throughput"], read_warn, read_crit, "upper"))
    state = _max_state(state, _grade_value(d["write_throughput"], write_warn, write_crit, "upper"))
    state = _max_state(state, _grade_value(d["util"], util_warn, util_crit, "upper"))

    return {
        "changed": False,
        "msg": "%s IO: read %f KB/s, write %f KB/s, util %f%%" % (item, d["read_throughput"], d["write_throughput"], d["util"]),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }