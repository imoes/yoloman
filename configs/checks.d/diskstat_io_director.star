# Disk IO Director — read-only Starlark check module
# Translates: checkmk.diskstat_io_director
# Source: cmk/plugins/hp_msa/agent_based/diskstat_io.py
# Data source: Linux kernel diskstats via /sys/block/<dev>/statistics/

DISKSTAT_DEFAULT_PARAMS = {
    "read_latency": (0, 0),
    "write_latency": (0, 0),
    "util": (80, 90),
    "throughput": (0, 0),
    "read_throughput": (0, 0),
    "write_throughput": (0, 0),
}

METRICS = [
    "read_throughput",
    "write_throughput",
    "read_latency",
    "write_latency",
    "util",
    "throughput",
]


def _to_float(value):
    if value == None or value == "":
        return 0.0
    s = str(value).strip()
    if s == "":
        return 0.0
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    whole = ""
    frac = ""
    dot_seen = False
    for ch in s:
        if ch == ".":
            if dot_seen:
                break
            dot_seen = True
        elif ch.isdigit():
            if dot_seen:
                frac = frac + ch
            else:
                whole = whole + ch
        else:
            break
    if whole == "" and frac == "":
        return 0.0
    w = int(whole) if whole != "" else 0
    f = 0.0
    if frac != "":
        f = int(frac)
        p = 1.0
        for _ in range(len(frac)):
            p = p / 10.0
        f = f * p
    result = w + f
    if neg:
        result = -result
    return result


def _level(value, warn, crit):
    if crit != None and crit != 0:
        if value >= crit:
            return "CRIT"
    if warn != None and warn != 0:
        if value >= warn:
            return "WARN"
    return "OK"


def _gather_directors(ctx):
    directors = []
    res = ctx.run(["ls", "-1", "/sys/block/"], mutates=False)
    if res.rc == 0 and res.stdout != "":
        for tok in res.stdout.split():
            name = tok.strip()
            if name == "":
                continue
            stat_base = "/sys/block/" + name + "/statistics"
            stat_res = ctx.stat(stat_base)
            if stat_res != None and stat_res.get("exists") and stat_res.get("is_dir"):
                directors.append(name)
    return directors


def main(ctx, params):
    if params.get("_discover"):
        directors = _gather_directors(ctx)
        discovery = []
        for d in directors:
            entry = {
                "item": d,
                "params": dict(DISKSTAT_DEFAULT_PARAMS),
                "metrics": list(METRICS),
            }
            discovery.append(entry)
        return {
            "changed": False,
            "msg": "discovered %d IO directors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if item == "" or item == None:
        directors = _gather_directors(ctx)
        if len(directors) == 0:
            return {
                "changed": False,
                "msg": "no IO directors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        item = directors[0]

    stat_base = "/sys/block/" + item + "/statistics"
    dir_res = ctx.stat(stat_base)
    if dir_res == None or not dir_res.get("exists") or not dir_res.get("is_dir"):
        return {
            "changed": False,
            "msg": "no such IO director: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    reads_res = ctx.run(["cat", stat_base + "/reads"], mutates=False)
    writes_res = ctx.run(["cat", stat_base + "/writes"], mutates=False)
    read_sectors_res = ctx.run(["cat", stat_base + "/read_sectors"], mutates=False)
    write_sectors_res = ctx.run(["cat", stat_base + "/write_sectors"], mutates=False)
    io_ticks_res = ctx.run(["cat", stat_base + "/io_ticks"], mutates=False)
    time_in_queue_res = ctx.run(["cat", stat_base + "/time_in_queue"], mutates=False)

    reads = _to_float(reads_res.stdout) if reads_res.rc == 0 else 0.0
    writes = _to_float(writes_res.stdout) if writes_res.rc == 0 else 0.0
    read_sectors = _to_float(read_sectors_res.stdout) if read_sectors_res.rc == 0 else 0.0
    write_sectors = _to_float(write_sectors_res.stdout) if write_sectors_res.rc == 0 else 0.0
    io_ticks = _to_float(io_ticks_res.stdout) if io_ticks_res.rc == 0 else 0.0
    time_in_queue = _to_float(time_in_queue_res.stdout) if time_in_queue_res.rc == 0 else 0.0

    read_throughput = read_sectors * 512.0
    write_throughput = write_sectors * 512.0

    total_ios = reads + writes
    if total_ios > 0:
        read_latency = io_ticks / total_ios
        write_latency = io_ticks / total_ios
    else:
        read_latency = 0.0
        write_latency = 0.0

    if total_ios > 0:
        util = time_in_queue / total_ios
    else:
        util = 0.0
    if util > 100.0:
        util = 100.0

    throughput = read_throughput + write_throughput

    metrics = {}
    metrics["read_throughput"] = read_throughput
    metrics["write_throughput"] = write_throughput
    metrics["read_latency"] = read_latency
    metrics["write_latency"] = write_latency
    metrics["util"] = util
    metrics["throughput"] = throughput

    util_warn = params.get("util_warn", params.get("warn", 80))
    util_crit = params.get("util_crit", params.get("crit", 90))

    state = _level(util, util_warn, util_crit)

    msg = "IO: r=%d w=%d util=%f%%" % (int(reads), int(writes), util)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }