def _fmt_bytes(n):
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    val = float(n)
    i = 0
    while val >= 1024.0 and i < len(units) - 1:
        val = val / 1024.0
        i = i + 1
    if i == 0:
        return "%d %s" % (n, units[i])
    return "%f %s" % (val, units[i])

def _get_param(params, key, default):
    if key in params:
        return params[key]
    return default

def _convert_levels(levels, base_value):
    if levels == None:
        return None
    lo_type = levels[0]
    if lo_type == "fixed":
        return levels
    vals = levels[1]
    lo_warn = vals[0] / 100.0 * base_value
    lo_crit = vals[1] / 100.0 * base_value
    return ["fixed", (lo_warn, lo_crit)]

def _grade_levels(value, levels_lower, levels_upper):
    state = "OK"
    if levels_upper != None:
        up_type, up_vals = levels_upper
        if up_type == "fixed":
            up_warn = up_vals[0]
            up_crit = up_vals[1]
        else:
            up_warn = up_vals[0] / 100.0 * value
            up_crit = up_vals[1] / 100.0 * value
        if value >= up_crit:
            state = "CRIT"
        elif value >= up_warn and state != "CRIT":
            state = "WARN"
    if levels_lower != None:
        lo_type, lo_vals = levels_lower
        if lo_type == "fixed":
            lo_warn = lo_vals[0]
            lo_crit = lo_vals[1]
        else:
            lo_warn = lo_vals[0] / 100.0 * value
            lo_crit = lo_vals[1] / 100.0 * value
        if value <= lo_crit:
            state = "CRIT"
        elif value <= lo_warn and state != "CRIT":
            state = "WARN"
    return state

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["hierarchy", "vm", "list", "--"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no Hyper-V host found",
                    "data": {"discovery": []}}
        discovery = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            vm_name = parts[0]
            discovery.append({
                "item": vm_name,
                "params": {
                    "min_ram": ["no_levels", None],
                    "max_ram": ["no_levels", None],
                    "check_demand": False,
                },
                "metrics": [
                    "hyperv_ram_metrics_vm_assigned_ram",
                    "hyperv_ram_metrics_vm_ram_demand",
                    "hyperv_ram_metrics_vm_start_ram",
                    "hyperv_ram_metrics_vm_max_ram",
                    "hyperv_ram_metrics_vm_min_ram",
                ],
            })
        return {"changed": False, "msg": "discovered %d VMs" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    res = ctx.run(["hierarchy", "vm", "list", "--"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no Hyper-V host found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    found = False
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == item:
            found = True
            break
    if not found:
        return {"changed": False, "msg": "VM not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    detail_res = ctx.run(["hierarchy", "vm", "list", item, "--"], mutates=False)
    if detail_res.rc != 0 or not detail_res.stdout:
        return {"changed": False, "msg": "no details for VM: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    string_table = [l.split() for l in detail_res.stdout.splitlines() if l.strip()]
    parsed = {}
    for line in string_table:
        parsed[line[0]] = " ".join(line[1:])
    assigned_ram = int(parsed.get("config.hardware.AssignedRAM", "0"))
    ram_demand = int(parsed.get("config.hardware.RAMDemand", "0"))
    start_ram = int(parsed.get("config.hardware.StartRAM", "0"))
    max_ram = int(parsed.get("config.hardware.MaxRAM", "0"))
    min_ram = int(parsed.get("config.hardware.MinRAM", "0"))
    is_dynamic = parsed.get("config.hardware.RAMType") == "dynamic"
    min_ram_param = _get_param(params, "min_ram", ["no_levels", None])
    max_ram_param = _get_param(params, "max_ram", ["no_levels", None])
    check_demand = _get_param(params, "check_demand", False)
    min_ram_levels = _convert_levels(min_ram_param, min_ram)
    max_ram_levels = _convert_levels(max_ram_param, max_ram)
    metric_name_prefix = "hyperv_ram_metrics_"
    metrics = {}
    metrics[metric_name_prefix + "vm_assigned_ram"] = assigned_ram
    state = _grade_levels(assigned_ram, min_ram_levels, max_ram_levels)
    if ram_demand > 0:
        if check_demand and ram_demand > assigned_ram:
            state = "WARN"
        metrics[metric_name_prefix + "vm_ram_demand"] = ram_demand
    metrics[metric_name_prefix + "vm_start_ram"] = start_ram
    metrics[metric_name_prefix + "vm_max_ram"] = max_ram
    metrics[metric_name_prefix + "vm_min_ram"] = min_ram
    details = "Dynamic memory Enabled: %s" % is_dynamic
    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": metrics, "details": details}}