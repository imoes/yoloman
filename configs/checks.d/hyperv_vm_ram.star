def _parse_hyperv_vm_ram(ctx):
    raw = {}
    res = ctx.run([
        "powershell",
        "-NoProfile",
        "-Command",
        "(Get-VM | Select-Object AssignedRAM, RAMDemand, StartRAM, MaxRAM, MinRAM, @{Name='RAMType';Expression={if($_.MemoryType -eq 'Dynamic'){'dynamic'}else{'static'}}} | Format-Table -HideTableHeaders -Wrap | Out-String).Trim()"
    ], mutates=False)
    if res.rc != 0:
        return None

    lines = res.stdout.splitlines()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        idx = line.find(" ")
        if idx == -1:
            continue
        key = line[:idx]
        value = line[idx + 1:].strip()
        if key:
            raw[key] = value

    return raw


def main(ctx, params):
    if params.get("_discover"):
        raw = _parse_hyperv_vm_ram(ctx)
        if raw == None:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {
                "min_ram": ("no_levels", None),
                "max_ram": ("no_levels", None),
                "check_demand": False
            }, "metrics": [
                "hyperv_ram_metrics_vm_assigned_ram",
                "hyperv_ram_metrics_vm_ram_demand",
                "hyperv_ram_metrics_vm_start_ram",
                "hyperv_ram_metrics_vm_max_ram",
                "hyperv_ram_metrics_vm_min_ram"
            ]}]}
        }

    raw = _parse_hyperv_vm_ram(ctx)
    if raw == None:
        return {
            "changed": False,
            "msg": "could not retrieve Hyper-V VM RAM data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    assigned_ram_str = raw.get("AssignedRAM", "0")
    ram_demand_str = raw.get("RAMDemand", "0")
    start_ram_str = raw.get("StartRAM", "0")
    max_ram_str = raw.get("MaxRAM", "0")
    min_ram_str = raw.get("MinRAM", "0")
    ram_type_str = raw.get("RAMType", "static")

    def to_int(s):
        s = s.strip()
        return int(s) if s.isdigit() else 0

    assigned_ram = to_int(assigned_ram_str)
    ram_demand = to_int(ram_demand_str)
    start_ram = to_int(start_ram_str)
    max_ram = to_int(max_ram_str)
    min_ram = to_int(min_ram_str)
    is_dynamic = ram_type_str == "dynamic"

    min_levels = params.get("min_ram", ("no_levels", None))
    max_levels = params.get("max_ram", ("no_levels", None))
    check_demand = params.get("check_demand", False)

    def _adjust_levels(levels, base_value):
        if levels[0] == "fixed":
            typ, (warn_pct, crit_pct) = levels
            warn_val = (warn_pct / 100.0) * base_value
            crit_val = (crit_pct / 100.0) * base_value
            return (typ, (warn_val, crit_val))
        return levels

    min_ram_levels = _adjust_levels(min_levels, min_ram) if min_levels[0] == "fixed" else min_levels
    max_ram_levels = _adjust_levels(max_levels, max_ram) if max_levels[0] == "fixed" else max_levels

    state = "OK"

    if min_ram_levels[0] != "no_levels":
        typ, (warn, crit) = min_ram_levels
        if assigned_ram <= crit:
            state = "CRIT"
        elif assigned_ram <= warn and state == "OK":
            state = "WARN"

    if max_ram_levels[0] != "no_levels":
        typ, (warn, crit) = max_ram_levels
        if assigned_ram >= crit:
            state = "CRIT"
        elif assigned_ram >= warn and state != "CRIT":
            state = "WARN"

    if ram_demand > 0:
        if check_demand and ram_demand > assigned_ram:
            state = "WARN"

    metrics = {
        "hyperv_ram_metrics_vm_assigned_ram": assigned_ram,
        "hyperv_ram_metrics_vm_start_ram": start_ram,
        "hyperv_ram_metrics_vm_max_ram": max_ram,
        "hyperv_ram_metrics_vm_min_ram": min_ram,
    }
    if ram_demand > 0:
        metrics["hyperv_ram_metrics_vm_ram_demand"] = ram_demand

    msg = "Current RAM: %d bytes" % assigned_ram
    if ram_demand > 0:
        msg = msg + ", Demand: %d bytes" % ram_demand
    if state != "OK":
        if ram_demand > 0 and check_demand and ram_demand > assigned_ram:
            msg = msg + " (Demand exceeds assigned RAM)"
    if not is_dynamic:
        msg = msg + ", Dynamic memory Disabled"
    else:
        msg = msg + ", Dynamic memory Enabled"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }