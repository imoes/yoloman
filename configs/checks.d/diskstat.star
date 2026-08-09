def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/diskstats"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no disks found", "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        names = []
        for line in lines:
            f = line.split()
            if len(f) < 4:
                continue
            name = f[2]
            names.append(name)

        # Exclude real partitions: a partition whose base disk (without trailing digits) also exists
        basenames = {}
        for n in names:
            i = len(n) - 1
            while i >= 0 and n[i].isdigit():
                i = i - 1
            basenames[n] = n[:i + 1]

        basenames_set = set(basenames.values())
        out = []
        for n in names:
            base = basenames[n]
            is_partition = len(n) > len(base) and base in basenames_set
            if is_partition:
                continue
            # Skip partitions that look like sda1 with no sda (XEN virtual)
            out.append({
                "item": n,
                "params": {
                    "util_crit": 90.0,
                    "read_latency_crit": 1.0,
                    "write_latency_crit": 1.0,
                    "queue_length_crit": 1000.0,
                },
                "metrics": ["read_throughput", "write_throughput", "read_ios", "write_ios", "utilization"],
            })
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/diskstats"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "no disk data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = res.stdout.splitlines()
    disk = None
    for line in lines:
        f = line.split()
        if len(f) < 4:
            continue
        if f[2] == item:
            disk = f
            break

    if disk == None:
        return {
            "changed": False,
            "msg": "no such disk: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fields (0-indexed in /proc/diskstats):
    # 0:major 1:minor 2:name 3:reads 4:merges 5:sectors_read 6:read_ticks
    # 7:writes 8:merges 9:sectors_written 10:write_ticks 11:ios_in_prog
    # 12:total_ticks 13:rq_ticks
    read_ios = int(disk[3])
    read_sectors = int(disk[5])
    read_ticks = int(disk[6])
    write_ios = int(disk[7])
    write_sectors = int(disk[9])
    write_ticks = int(disk[10])
    ios_in_prog = int(disk[11])
    total_ticks = int(disk[12])

    read_throughput = read_sectors * 512
    write_throughput = write_sectors * 512
    utilization = total_ticks / 1000.0  # 0..1 fraction

    warn = params.get("util_warn", 80.0)
    crit = params.get("util_crit", 90.0)
    util_pct = utilization * 100.0

    if util_pct >= crit:
        state = "CRIT"
    elif util_pct >= warn:
        state = "WARN"
    else:
        state = "OK"

    metrics = {
        "read_throughput": read_throughput,
        "write_throughput": write_throughput,
        "read_ios": read_ios,
        "write_ios": write_ios,
        "utilization": util_pct,
        "queue_length": ios_in_prog,
    }

    return {
        "changed": False,
        "msg": "Utilization: %f%% (%d reads, %d writes)" % (util_pct, read_ios, write_ios),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "utilization %f%% (warn %s, crit %s)" % (util_pct, str(warn), str(crit)),
        },
    }