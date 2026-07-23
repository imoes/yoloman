def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx)

    item = params.get("item", "")
    return _check_item(ctx, item, params)


def _discover(ctx):
    res = ctx.run(["cat", "/proc/diskstats"], mutates=False)
    devices = _parse_proc_diskstat(ctx, res.stdout)
    if not devices:
        return {"changed": False, "msg": "discovered 0 devices",
                "data": {"discovery": []}}

    items = []
    for devname, _ in devices.items():
        if devname.startswith("dm-"):
            continue
        if _is_partition(devname):
            continue
        items.append({"item": devname, "params": {}, "metrics": ["read_ios", "write_ios", "read_throughput", "write_throughput", "utilization", "queue_length", "latency"]})

    return {"changed": False, "msg": "discovered %d devices" % len(items),
            "data": {"discovery": items}}


def _is_partition(name):
    if not name:
        return False
    return name[-1].isdigit()


def _check_item(ctx, item, params):
    res = ctx.run(["cat", "/proc/diskstats"], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "failed to read /proc/diskstats",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    devices = _parse_proc_diskstat(ctx, res.stdout)
    disk = None
    if item in devices:
        disk = devices[item]
    else:
        for k, v in devices.items():
            if k.startswith(item + ":"):
                disk = v
                break

    if disk == None:
        return {"changed": False,
                "msg": "no such device: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ts_res = ctx.run(["date", "+%s"], mutates=False)
    this_time = int(ts_res.stdout) if ts_res.rc == 0 and ts_res.stdout.isdigit() else 0

    last_res = ctx.run(["cat", "/var/lib/yolo-man/diskstat_" + item + ".json"], mutates=False)
    last = None
    if last_res.rc == 0 and last_res.stdout.strip():
        last = json.decode(last_res.stdout)

    disk_rates = _compute_rates_single_disk(disk, last, this_time)

    state_entry = {
        "timestamp": disk["timestamp"],
        "read_ios": disk["read_ios"],
        "write_ios": disk["write_ios"],
        "read_throughput": disk["read_throughput"],
        "write_throughput": disk["write_throughput"],
        "read_ticks": disk["read_ticks"],
        "write_ticks": disk["write_ticks"],
        "utilization": disk["utilization"],
    }
    ctx.run(["mkdir", "-p", "/var/lib/yolo-man"], mutates=False)
    ctx.file_write("/var/lib/yolo-man/diskstat_" + item + ".json", json.encode(state_entry))

    state, summary, metrics = _check_diskstat_dict_legacy(params, disk_rates)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }


def _parse_proc_diskstat(ctx, output):
    lines = output.strip().split("\n")
    devices = {}
    ts_res = ctx.run(["date", "+%s"], mutates=False)
    timestamp = int(ts_res.stdout) if ts_res.rc == 0 and ts_res.stdout.isdigit() else 0

    for line in lines:
        parts = line.split()
        if len(parts) < 14:
            continue

        major = int(parts[0]) if parts[0].isdigit() else 0
        minor = int(parts[1]) if parts[1].isdigit() else 0
        name = parts[2]
        reads = int(parts[3]) if parts[3].lstrip("-").isdigit() else 0
        reads_merges = int(parts[4]) if parts[4].lstrip("-").isdigit() else 0
        read_sectors = int(parts[5]) if parts[5].lstrip("-").isdigit() else 0
        read_ticks = int(parts[6]) if parts[6].lstrip("-").isdigit() else 0
        writes = int(parts[7]) if parts[7].lstrip("-").isdigit() else 0
        writes_merges = int(parts[8]) if parts[8].lstrip("-").isdigit() else 0
        write_sectors = int(parts[9]) if parts[9].lstrip("-").isdigit() else 0
        write_ticks = int(parts[10]) if parts[10].lstrip("-").isdigit() else 0
        ios_in_prog = int(parts[11]) if parts[11].lstrip("-").isdigit() else 0
        total_ticks = int(parts[12]) if parts[12].lstrip("-").isdigit() else 0

        devices[name] = {
            "timestamp": timestamp,
            "read_ios": reads,
            "write_ios": writes,
            "read_throughput": read_sectors * 512,
            "write_throughput": write_sectors * 512,
            "read_ticks": float(read_ticks) / 1000.0,
            "write_ticks": float(write_ticks) / 1000.0,
            "utilization": float(total_ticks) / 1000.0,
            "queue_length": ios_in_prog,
        }
    return devices


def _compute_rates_single_disk(disk, last, this_time):
    disk_rates = {}
    disk_rates["queue_length"] = disk["queue_length"]

    if last == None or last.get("timestamp") == None or last["timestamp"] == disk["timestamp"]:
        disk_rates["read_ios"] = 0.0
        disk_rates["write_ios"] = 0.0
        disk_rates["read_throughput"] = 0.0
        disk_rates["write_throughput"] = 0.0
        disk_rates["read_ticks"] = 0.0
        disk_rates["write_ticks"] = 0.0
        disk_rates["utilization"] = 0.0
        disk_rates["latency"] = 0.0
        disk_rates["average_wait"] = 0.0
        disk_rates["average_request_size"] = 0.0
        disk_rates["average_read_wait"] = 0.0
        disk_rates["average_read_request_size"] = 0.0
        disk_rates["average_write_wait"] = 0.0
        disk_rates["average_write_request_size"] = 0.0
        return disk_rates

    delta = float(this_time - last["timestamp"])
    if delta <= 0.0:
        delta = 1.0

    d_read_ios = float(disk["read_ios"] - last["read_ios"])
    d_write_ios = float(disk["write_ios"] - last["write_ios"])
    d_read_throughput = float(disk["read_throughput"] - last["read_throughput"])
    d_write_throughput = float(disk["write_throughput"] - last["write_throughput"])
    d_read_ticks = float(disk["read_ticks"] - last["read_ticks"])
    d_write_ticks = float(disk["write_ticks"] - last["write_ticks"])
    d_utilization = float(disk["utilization"] - last["utilization"])

    disk_rates["read_ios"] = d_read_ios / delta
    disk_rates["write_ios"] = d_write_ios / delta
    disk_rates["read_throughput"] = d_read_throughput / delta
    disk_rates["write_throughput"] = d_write_throughput / delta
    disk_rates["read_ticks"] = d_read_ticks / delta
    disk_rates["write_ticks"] = d_write_ticks / delta
    disk_rates["utilization"] = d_utilization / delta

    total_ios_rate = disk_rates["read_ios"] + disk_rates["write_ios"]
    total_bytes_rate = disk_rates["read_throughput"] + disk_rates["write_throughput"]

    if total_ios_rate > 0.0:
        disk_rates["latency"] = disk_rates["utilization"] / total_ios_rate
        disk_rates["average_wait"] = (disk_rates["read_ticks"] + disk_rates["write_ticks"]) / total_ios_rate
        disk_rates["average_request_size"] = total_bytes_rate / total_ios_rate
    else:
        disk_rates["latency"] = 0.0
        disk_rates["average_wait"] = 0.0
        disk_rates["average_request_size"] = 0.0

    if disk_rates["read_ios"] > 0.0:
        disk_rates["average_read_wait"] = disk_rates["read_ticks"] / disk_rates["read_ios"]
        disk_rates["average_read_request_size"] = disk_rates["read_throughput"] / disk_rates["read_ios"]
    else:
        disk_rates["average_read_wait"] = 0.0
        disk_rates["average_read_request_size"] = 0.0

    if disk_rates["write_ios"] > 0.0:
        disk_rates["average_write_wait"] = disk_rates["write_ticks"] / disk_rates["write_ios"]
        disk_rates["average_write_request_size"] = disk_rates["write_throughput"] / disk_rates["write_ios"]
    else:
        disk_rates["average_write_wait"] = 0.0
        disk_rates["average_write_request_size"] = 0.0

    return disk_rates


def _check_diskstat_dict_legacy(params, disk):
    warn_util = params.get("utilization", 70.0)
    crit_util = params.get("utilization", 90.0)
    warn_lat = params.get("latency", 0.06)
    crit_lat = params.get("latency", 0.1)

    util_pct = disk.get("utilization", 0.0) * 100.0
    lat = disk.get("latency", 0.0)

    state = "OK"
    if util_pct >= crit_util or lat >= crit_lat:
        state = "CRIT"
    elif util_pct >= warn_util or lat >= warn_lat:
        state = "WARN"

    parts = []
    if "read_ios" in disk:
        parts.append("read: %f IOPS" % disk["read_ios"])
    if "write_ios" in disk:
        parts.append("write: %f IOPS" % disk["write_ios"])
    parts.append("util: %f%%" % util_pct)
    if lat != 0.0:
        parts.append("lat: %f ms" % (lat * 1000.0))

    summary = ", ".join(parts)

    metrics = {
        "read_ios": disk.get("read_ios", 0.0),
        "write_ios": disk.get("write_ios", 0.0),
        "utilization": util_pct,
        "latency": lat,
    }

    return state, summary, metrics