# ===== check plugin: cmk/plugins/cadvisor/agent_based/cadvisor_diskstat.py =====
# Translated to a read-only Starlark check module for the yolo-man agent.

def _is_number(s):
    if s == None:
        return False
    st = str(s)
    if len(st) == 0:
        return False
    # allow leading +-, then digits with optional single dot
    body = st
    if body[0] == "+" or body[0] == "-":
        body = body[1:]
    if len(body) == 0:
        return False
    has_dot = False
    for ch in body:
        if ch == ".":
            if has_dot:
                return False
            has_dot = True
        elif ch < "0" or ch > "9":
            return False
    return True


def _to_float(s):
    if not _is_number(s):
        return None
    st = str(s)
    neg = False
    idx = 0
    if st[0] == "-":
        neg = True
        idx = 1
    elif st[0] == "+":
        idx = 1
    val = 0.0
    frac = 0.0
    seen_dot = False
    while idx < len(st):
        ch = st[idx]
        if ch == ".":
            seen_dot = True
        else:
            d = ord(ch) - ord("0")
            if seen_dot:
                frac = frac * 0.1 + d * 0.1
            else:
                val = val * 10.0 + d
        idx = idx + 1
    if seen_dot:
        val = val + frac
    return 0.0 - val if neg else val


def _probe_cadvisor_host(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 8080)
    url = "http://%s:%s/metrics" % (host, port)
    res = ctx.run(["curl", "-fsS", "--max-time", "5", url], mutates=False)
    if res.rc == 127 or res.skipped:
        return None, "cAdvisor/curl not available on host %s" % host
    if res.rc != 0:
        return None, "cAdvisor not reachable at %s (rc=%d)" % (url, res.rc)
    return url, ""


def _extract_diskstat(body):
    devices = {}
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "{" not in line:
            continue
        name_part, _, value_part = line.partition(" ")
        if not value_part:
            continue
        metric_name, _, label_part = name_part.partition("{")
        label_part = label_part.rstrip("}")
        labels = {}
        for pair in label_part.split(","):
            k, _, v = pair.partition("=")
            labels[k.strip()] = v.strip().strip('"')
        dev = labels.get("device")
        if dev == None:
            continue
        value = _to_float(value_part)
        if value == None:
            continue
        device = devices.get(dev, {})
        device[metric_name] = value
        devices[dev] = device
    return devices


def _diskstat_metrics(dev):
    metrics = {}
    metrics["disk_read_operation"] = dev.get("container_fs_reads")
    metrics["disk_write_operation"] = dev.get("container_fs_writes")
    metrics["disk_read_throughput"] = dev.get("container_fs_read_bytes_total")
    metrics["disk_write_throughput"] = dev.get("container_fs_write_bytes_total")
    metrics["disk_utilisation"] = dev.get("container_fs_io_time_ns")
    return metrics


def main(ctx, params):
    if params.get("_discover"):
        url, err = _probe_cadvisor_host(ctx, params)
        if url == None:
            return {"changed": False, "msg": err, "data": {"discovery": []}}
        res = ctx.run(["curl", "-fsS", "--max-time", "5", url], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "cAdvisor metrics unavailable", "data": {"discovery": []}}
        devices = _extract_diskstat(res.stdout)
        out = []
        for dev_name in devices:
            out.append({
                "item": dev_name,
                "params": {},
                "metrics": ["disk_utilisation", "disk_read_operation", "disk_write_operation",
                            "disk_read_throughput", "disk_write_throughput"],
            })
        return {"changed": False, "msg": "discovered %d disks" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    url, err = _probe_cadvisor_host(ctx, params)
    if url == None:
        return {"changed": False, "msg": err,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run(["curl", "-fsS", "--max-time", "5", url], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cAdvisor metrics unavailable",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    devices = _extract_diskstat(res.stdout)
    dev = devices.get(item)
    if dev == None:
        return {"changed": False, "msg": "no disk %s found" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    metrics = _diskstat_metrics(dev)
    util = metrics.get("disk_utilisation")
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)
    state = "OK"
    details = "Disk IO for %s" % item
    metric_vals = {}
    for k in metrics:
        v = metrics[k]
        if v != None:
            metric_vals[k] = v
    if util != None:
        if util >= crit:
            state = "CRIT"
        elif util >= warn:
            state = "WARN"
        details = details + ", utilization: %f" % util
    return {"changed": False, "msg": details,
        "data": {"state": state, "metrics": metric_vals, "details": ""}}