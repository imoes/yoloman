# ===== Starlark module: diskstat_io_director =====
# Read-only check for Disk IO Director — translated from Checkmk plugin

# Default parameters for discovery (diskstat.DISKSTAT_DEFAULT_PARAMS)
DISKSTAT_DEFAULT_PARAMS = {
    "summary": True,
    "average": "600",
    "latency": (10.0, 20.0),
    "queue_length": (10, 20),
    "total_utilization": (70.0, 90.0),
}

def _parse_hp_msa_disk(values):
    # Guard before parsing: ensure required keys exist
    read_numeric = values.get("data-read-numeric", "")
    write_numeric = values.get("data-written-numeric", "")
    read_latency = values.get("read-latency", "")
    write_latency = values.get("write-latency", "")
    read_ops = values.get("read-operations", "")
    write_ops = values.get("write-operations", "")

    # Check if numeric strings are valid (empty or non-digit)
    def _safe_float(s):
        return float(s) if s != "" and s.replace(".", "").replace("-", "").isdigit() else 0.0

    return {
        "read_throughput": _safe_float(read_numeric),
        "write_throughput": _safe_float(write_numeric),
        "read_latency": _safe_float(read_latency),
        "write_latency": _safe_float(write_latency),
        "read_ops": _safe_float(read_ops),
        "write_ops": _safe_float(write_ops),
    }

def _parse_diskstat_section(section):
    new_section = {}
    for name, values in section.items():
        parsed = _parse_hp_msa_disk(values)
        new_section[name] = parsed
    return new_section

def _compute_rates(disk):
    return dict(disk)

def _check_diskstat_dict_legacy(params, disk):
    latency_warn, latency_crit = params.get("latency", (10.0, 20.0))
    total_util_warn, total_util_crit = params.get("total_utilization", (70.0, 90.0))

    read_throughput = disk.get("read_throughput", 0.0)
    write_throughput = disk.get("write_throughput", 0.0)
    read_ops = disk.get("read_ops", 0.0)
    write_ops = disk.get("write_ops", 0.0)
    read_latency = disk.get("read_latency", 0.0)
    write_latency = disk.get("write_latency", 0.0)

    total_throughput = read_throughput + write_throughput
    total_ops = read_ops + write_ops
    avg_latency = (read_latency + write_latency) / 2.0 if (read_latency + write_latency) > 0 else 0.0

    utilization = min(100.0, max(0.0, total_ops * avg_latency / 10.0))

    state = "OK"
    msg_parts = []

    if avg_latency >= latency_crit:
        state = "CRIT"
    elif avg_latency >= latency_warn:
        state = "WARN" if state != "CRIT" else state
    msg_parts.append("Latency: %f ms" % avg_latency)

    if utilization >= total_util_crit:
        state = "CRIT"
    elif utilization >= total_util_warn:
        state = "WARN" if state != "CRIT" else state
    msg_parts.append("Util: %f%%" % utilization)

    msg_parts.append("Throughput: %f MB/s" % (total_throughput / 1024.0 / 1024.0))
    msg_parts.append("Ops: %f/s" % total_ops)

    metrics = {
        "read_throughput": read_throughput,
        "write_throughput": write_throughput,
        "read_latency": read_latency,
        "write_latency": write_latency,
        "read_ops": read_ops,
        "write_ops": write_ops,
        "avg_latency": avg_latency,
        "utilization": utilization,
    }

    return {
        "state": state,
        "msg": ", ".join(msg_parts),
        "metrics": metrics,
    }

def main(ctx, params):
    if params.get("_discover"):
        url = params.get("url", "http://localhost:23222")
        username = params.get("username", "")
        password = params.get("password", "")

        res = ctx.run(["curl", "-sk", "-u", username + ":" + password, url + "/rest/Disk"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch MSA disk list (curl rc=%d)" % res.rc,
                    "data": {"discovery": []}}

        if res.stdout == "":
            return {"changed": False, "msg": "empty response from MSA REST API",
                    "data": {"discovery": []}}

        data = json.decode(res.stdout)

        disks = data.get("member", [])
        out = []
        for d in disks:
            name = d.get("name", "")
            if name == "":
                continue
            out.append({"item": name, "params": DISKSTAT_DEFAULT_PARAMS,
                        "metrics": ["read_throughput", "write_throughput", "avg_latency", "utilization"]})
        return {"changed": False, "msg": "discovered %d disks" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    url = params.get("url", "http://localhost:23222")
    username = params.get("username", "")
    password = params.get("password", "")

    res = ctx.run(["curl", "-sk", "-u", username + ":" + password, url + "/rest/Disk"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch MSA disk data (curl rc=%d)" % res.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if res.stdout == "":
        return {"changed": False, "msg": "empty MSA disk data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)

    disks = data.get("member", [])
    disk_raw = None
    for d in disks:
        if d.get("name", "") == item:
            disk_raw = d
            break

    if disk_raw == None:
        return {"changed": False, "msg": "disk not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = {}
    section[item] = disk_raw
    parsed_section = _parse_diskstat_section(section)

    if item not in parsed_section:
        return {"changed": False, "msg": "could not parse disk data: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    disk = parsed_section[item]
    disk_with_rates = _compute_rates(disk)
    result = _check_diskstat_dict_legacy(params, disk_with_rates)

    return {
        "changed": False,
        "msg": result["msg"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": "",
        },
    }
