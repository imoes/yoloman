def main(ctx, params):
    # ----- DISCOVERY MODE -----
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/yolo-man/agent/cadvisor_diskstat"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 items (no cadvisor_diskstat data)",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout) if res.stdout else None
        if data == None:
            return {"changed": False, "msg": "discovered 0 items (invalid cadvisor_diskstat JSON)",
                    "data": {"discovery": []}}

        # Expected format: {"<metric>": [{"value": "<number>"}]}
        discovered = []
        for metric_name, entries in data.items():
            if len(entries) != 1:
                continue
            # Map Checkmk metric names to internal names used by check_diskstat_dict_legacy
            mapping = {
                "disk_utilisation": "utilization",
                "disk_write_operation": "write_ios",
                "disk_read_operation": "read_ios",
                "disk_write_throughput": "write_throughput",
                "disk_read_throughput": "read_throughput",
            }
            internal_name = mapping.get(metric_name)
            if internal_name != None:
                # Use "Summary" as item name (single-service check)
                discovered.append({"item": "Summary",
                                   "params": {},
                                   "metrics": ["utilization", "read_ios", "write_ios",
                                               "read_throughput", "write_throughput"]})
                break  # only one item ("Summary") ever
        return {"changed": False, "msg": "discovered %d items" % len(discovered),
                "data": {"discovery": discovered}}

    # ----- CHECK MODE -----
    item = params.get("item", "")
    if item != "Summary":
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["cat", "/var/lib/yolo-man/agent/cadvisor_diskstat"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "cadvisor_diskstat data missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)
    if data == None:
        return {"changed": False, "msg": "cadvisor_diskstat data invalid (not JSON)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Map metrics to internal names
    mapping = {
        "disk_utilisation": "utilization",
        "disk_write_operation": "write_ios",
        "disk_read_operation": "read_ios",
        "disk_write_throughput": "write_throughput",
        "disk_read_throughput": "read_throughput",
    }

    disk = {}
    for metric_name, entries in data.items():
        if len(entries) != 1:
            continue
        value_str = entries[0].get("value")
        if value_str == None or value_str == "":
            continue
        s = str(value_str).strip()
        # Check if numeric (allow optional leading minus, one dot)
        if s.startswith("-"):
            s = s[1:]
        if s == "" or s.find("-") >= 0 or s.count(".") > 1:
            continue
        # All remaining characters must be digits or dot
        numeric = s.replace(".", "")
        if not numeric.isdigit():
            continue
        val = float(value_str)
        internal = mapping.get(metric_name)
        if internal != None:
            disk[internal] = val

    if not disk:
        return {"changed": False, "msg": "no diskstat metrics found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Apply legacy diskstat check thresholds (same defaults as Checkmk)
    util_warn = params.get("utilization", (80.0, 90.0))
    read_ios_warn = params.get("read_ios", (0.0, 0.0))
    write_ios_warn = params.get("write_ios", (0.0, 0.0))
    read_throughput_warn = params.get("read_throughput", (0.0, 0.0))
    write_throughput_warn = params.get("write_throughput", (0.0, 0.0))

    def grade(val, thresholds):
        if thresholds == None or thresholds == (0.0, 0.0):
            return "OK"
        warn, crit = thresholds
        if val >= crit:
            return "CRIT"
        if val >= warn:
            return "WARN"
        return "OK"

    state = "OK"
    metrics = {}

    if "utilization" in disk:
        val = disk["utilization"]
        st = grade(val, util_warn)
        if st != "OK":
            state = st
        metrics["utilization"] = val

    if "read_ios" in disk:
        val = disk["read_ios"]
        st = grade(val, read_ios_warn)
        if st != "OK":
            state = st
        metrics["read_ios"] = val

    if "write_ios" in disk:
        val = disk["write_ios"]
        st = grade(val, write_ios_warn)
        if st != "OK":
            state = st
        metrics["write_ios"] = val

    if "read_throughput" in disk:
        val = disk["read_throughput"]
        st = grade(val, read_throughput_warn)
        if st != "OK":
            state = st
        metrics["read_throughput"] = val

    if "write_throughput" in disk:
        val = disk["write_throughput"]
        st = grade(val, write_throughput_warn)
        if st != "OK":
            state = st
        metrics["write_throughput"] = val

    # Build human-readable message
    parts = []
    for name in ["utilization", "read_ios", "write_ios", "read_throughput", "write_throughput"]:
        if name in disk:
            if name == "utilization":
                parts.append("%s: %f%%" % (name, disk[name]))
            elif name.endswith("throughput"):
                parts.append("%s: %f MB/s" % (name, disk[name] / (1024*1024)))
            else:
                parts.append("%s: %f" % (name, disk[name]))
    msg = ", ".join(parts) if parts else "no metrics"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}