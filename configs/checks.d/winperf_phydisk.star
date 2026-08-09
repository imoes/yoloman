_LINE_TO_METRIC = {
    "-14": "read_throughput",
    "-12": "write_throughput",
    "-20": "read_ios",
    "-18": "write_ios",
    "1168": "read_ql",
    "1170": "write_ql",
    "-24": "average_read_wait",
    "-26": "average_write_wait",
}

def _parse_winperf_phydisk(string_table):
    if len(string_table) <= 1:
        return None
    header_row = string_table[0]
    timestamp = float(header_row[0])
    frequency = None
    if len(header_row) > 2:
        freq_str = header_row[2]
        if freq_str.isdigit() or (freq_str.startswith("-") and freq_str[1:].isdigit()):
            frequency = int(freq_str)
    disk_template = {"timestamp": timestamp}
    if frequency != None:
        disk_template["frequency"] = frequency
    instances = string_table[1]
    inst_line = instances[0]
    if inst_line.find("instances:") == -1:
        return {}
    parts = inst_line.split(" ")
    disk_labels = []
    for i in range(2, len(parts)):
        part = parts[i]
        if part != "":
            idx = part.find("_")
            if idx != -1:
                disk_labels.append([part[0:idx], part[idx+1:]])
            else:
                disk_labels.append([part, part])
    disks = {}
    for disk_info in disk_labels:
        num = disk_info[0]
        name = disk_info[1]
        new_disk = disk_template.copy()
        if name in disks:
            disks[num + "_" + name] = new_disk
        else:
            disks[name] = new_disk
    for row in string_table[2:]:
        if len(row) < 3:
            continue
        metric_id = row[0]
        if metric_id not in _LINE_TO_METRIC:
            continue
        metric_name = _LINE_TO_METRIC[metric_id]
        if metric_name.startswith("average") and len(row) > 2 and row[len(row)-1] == "average_base":
            metric_name = metric_name + "_base"
        values = row[1:len(row)-1]
        for i in range(0, len(values)):
            val_str = values[i]
            val = 0
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                val = int(val_str)
            disk_names = list(disks.keys())
            if i < len(disk_names):
                disk_name = disk_names[i]
                disks[disk_name][metric_name] = val
    return disks

def _is_work_metric(metric):
    return metric != "timestamp" and metric != "frequency" and not metric.endswith("_base")

def _compute_rates_single_disk(disk, value_store, suffix):
    disk_with_rates = {}
    timestamp = disk["timestamp"]
    frequency = disk.get("frequency")
    bad_results = False
    for metric, value in disk.items():
        if not _is_work_metric(metric):
            continue
        denom_value = 1.0
        if metric.endswith("ql"):
            denom_value = 10000000.0
        elif metric.startswith("average") or metric.endswith("wait"):
            denom_key = metric + "_base"
            denom_raw = disk.get(denom_key)
            if frequency == None:
                bad_results = True
                continue
            if denom_raw == None:
                bad_results = True
                continue
            denom_store_key = denom_key + suffix
            prev = value_store.get(denom_store_key)
            if prev == None:
                bad_results = True
                continue
            prev_time = prev["timestamp"]
            prev_value = prev["value"]
            if timestamp <= prev_time:
                bad_results = True
                continue
            denom_rate = (denom_raw - prev_value) / (timestamp - prev_time)
            if denom_rate < 0:
                bad_results = True
                continue
            denom_value = denom_rate * frequency
        store_key = metric + suffix
        prev = value_store.get(store_key)
        if prev == None:
            bad_results = True
            continue
        prev_time = prev["timestamp"]
        prev_value = prev["value"]
        if timestamp <= prev_time:
            bad_results = True
            continue
        nom = (value - prev_value) / (timestamp - prev_time)
        if nom < 0:
            bad_results = True
            continue
        if denom_value == 0 and nom == 0:
            disk_with_rates[metric] = 0.0
        elif denom_value != 0:
            disk_with_rates[metric] = nom / denom_value
        else:
            bad_results = True
    if bad_results:
        fail("Initializing counters!")
    return disk_with_rates

def _get_value_store(ctx):
    path = "/tmp/checkmk_winperf_phydisk_v1.json"
    if ctx.file_exists(path):
        content = ctx.file_read(path)
        return json.decode(content)
    return {}

def _save_value_store(ctx, store):
    path = "/tmp/checkmk_winperf_phydisk_v1.json"
    ctx.file_write(path, json.encode(store))

def _apply_thresholds(disk, params, value_store):
    warn = params.get("read_wait", (0.02, 0.05))
    crit = params.get("write_wait", (0.05, 0.1))
    if len(warn) < 2:
        warn = (0.02, 0.05)
    if len(crit) < 2:
        crit = (0.05, 0.1)
    read_wait = disk.get("average_read_wait", 0)
    write_wait = disk.get("average_write_wait", 0)
    if read_wait >= crit[1] or write_wait >= crit[1]:
        return "CRIT", "read_wait=%fs write_wait=%fs" % (read_wait, write_wait)
    if read_wait >= warn[1] or write_wait >= warn[1]:
        return "WARN", "read_wait=%fs write_wait=%fs" % (read_wait, write_wait)
    return "OK", "read_wait=%fs write_wait=%fs" % (read_wait, write_wait)

def main(ctx, params):
    discover = params.get("_discover")
    if discover:
        res = ctx.run(["type", "C:\\Windows\\System32\\logfiles\\wmi\\winperf_phydisk.txt"], mutates=False)
        if res.rc != 0:
            res = ctx.run(["type", "C:\\ProgramData\\Checkmk\\agent\\log\\winperf_phydisk.txt"], mutates=False)
        if res.rc != 0:
            res = ctx.run(["cmd", "/c", "type", "C:\\Windows\\System32\\logfiles\\wmi\\winperf_phydisk.txt"], mutates=False)
        if res.rc != 0:
            out = []
            return {"changed": False, "msg": "discovered 0 disks", "data": {"discovery": out}}
        lines = res.stdout.split("\n")
        string_table = []
        current_row = []
        for line in lines:
            stripped = line.strip()
            if stripped == "":
                continue
            parts = stripped.split()
            if len(parts) >= 2:
                string_table.append(parts)
            else:
                if len(current_row) > 0:
                    string_table.append(current_row)
                current_row = []
        section = _parse_winperf_phydisk(string_table)
        if section == None:
            section = {}
        out = []
        for name, disk in section.items():
            if name != "timestamp" and name != "frequency":
                out.append({"item": name, "params": {"read_wait": (0.02, 0.05), "write_wait": (0.05, 0.1)},
                            "metrics": ["read_throughput", "write_throughput", "read_ios", "write_ios",
                                       "read_ql", "write_ql", "average_read_wait", "average_write_wait"]})
        return {"changed": False, "msg": "discovered %d disks" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["type", "C:\\Windows\\System32\\logfiles\\wmi\\winperf_phydisk.txt"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["type", "C:\\ProgramData\\Checkmk\\agent\\log\\winperf_phydisk.txt"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["cmd", "/c", "type", "C:\\Windows\\System32\\logfiles\\wmi\\winperf_phydisk.txt"], mutates=False)
    lines = res.stdout.split("\n")
    string_table = []
    current_row = []
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
            current_row = []
        parts = stripped.split()
        if len(parts) >= 2:
            string_table.append(parts)
        else:
            if len(current_row) > 0:
                string_table.append(current_row)
            current_row = []
    section = _parse_winperf_phydisk(string_table)
    if section == None:
        section = {}
    value_store = _get_value_store(ctx)
    if item == "SUMMARY":
        disks_with_rates = {}
        for name, disk in section.items():
            if name != "timestamp" and name != "frequency":
                disk_with_rates = _compute_rates_single_disk(disk, value_store, "")
                disks_with_rates[name] = disk_with_rates
        if len(disks_with_rates) == 0:
            fail("no disks")
        avg_disk = {}
        metrics_to_avg = ["read_throughput", "write_throughput", "read_ios", "write_ios",
                          "read_ql", "write_ql", "average_read_wait", "average_write_wait"]
        for m in metrics_to_avg:
            total = 0.0
            count = 0
            for d in disks_with_rates.values():
                if m in d:
                    total += d[m]
                    count += 1
            if count > 0:
                avg_disk[m] = total / count
        disk_with_rates = avg_disk
    else:
        if item not in section:
            _save_value_store(ctx, value_store)
            return {"changed": False, "msg": "disk not found: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        disk = section[item]
        disk_with_rates = _compute_rates_single_disk(disk, value_store, "")
    _save_value_store(ctx, value_store)
    state, details = _apply_thresholds(disk_with_rates, params, value_store)
    metrics = {}
    for m in ["read_throughput", "write_throughput", "read_ios", "write_ios",
              "read_ql", "write_ql", "average_read_wait", "average_write_wait"]:
        if m in disk_with_rates:
            metrics[m] = disk_with_rates[m]
    return {"changed": False, "msg": details, "data": {"state": state, "metrics": metrics, "details": details}}