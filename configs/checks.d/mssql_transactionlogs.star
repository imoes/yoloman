# ===== Starlark check module: mssql_transactionlogs =====
# Read-only translation of Checkmk's mssql_transactionlogs check
# Gathers data via agent_section_mssql_transactionlogs format from host

# Agent section format (6 or 8 columns):
# 6-col: database file_name physical_name max_size allocated_size used_size
# 8-col: instance database file_name physical_name max_size allocated_size used_size unlimited_flag

def _format_item_mssql_datafiles(inst, database, file_name):
    if inst == None:
        return database + "." + file_name
    if file_name == None:
        return inst + "." + database
    return inst + "." + database + "." + file_name

def _effective_max_size(max_size, free_size, used_size, unlimited):
    max_size_float = max_size if max_size != None else 0.0
    if free_size == None:
        return max_size_float
    total_size = free_size + used_size
    if unlimited:
        return total_size
    return min(max_size_float, total_size)

def _datafile_usage(instances, available_bytes):
    max_size_sum = 0.0
    allocated_size_sum = 0.0
    used_size_sum = 0.0
    unlimited = False
    used_mountpoints = []
    for inst_dict in instances:
        unlimited = unlimited or inst_dict["unlimited"]
        allocated_size_sum = allocated_size_sum + (inst_dict["allocated_size"] if inst_dict["allocated_size"] != None else 0.0)
        used_size = inst_dict["used_size"] if inst_dict["used_size"] != None else 0.0
        used_size_sum = used_size_sum + used_size
        mountpoint = inst_dict["mountpoint"].lower()
        filesystem_free_size = available_bytes.get(mountpoint)
        found_mp = False
        for mp in used_mountpoints:
            if mp == mountpoint:
                found_mp = True
                break
        if found_mp:
            filesystem_free_size = 0.0
        else:
            used_mountpoints.append(mountpoint)
        max_size = _effective_max_size(inst_dict["max_size"], filesystem_free_size, used_size, inst_dict["unlimited"])
        max_size_sum = max_size_sum + max_size
    return {"used": used_size_sum, "allocated": allocated_size_sum, "max": max_size_sum}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/mk-transactionlogs"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "cannot read transactionlogs agent section",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        section = {}
        for line in lines:
            fields = line.split("\t")
            if len(fields) != 6 and len(fields) != 8:
                continue
            if fields[-1].startswith("ERROR: "):
                continue
            if len(fields) == 6:
                inst = None
                database = fields[0]
                file_name = fields[1]
                physical_name = fields[2]
                max_size_str = fields[3]
                allocated_size_str = fields[4]
                used_size_str = fields[5]
                unlimited = False
            else:
                inst = fields[0]
                database = fields[1]
                file_name = fields[2]
                physical_name = fields[3]
                max_size_str = fields[4]
                allocated_size_str = fields[5]
                used_size_str = fields[6]
                unlimited = fields[7] == "1"
            key = (inst, database, file_name)
            mssql_instance = section.setdefault(key, {
                "unlimited": unlimited,
                "max_size": None,
                "allocated_size": None,
                "used_size": None,
                "mountpoint": physical_name.lower()
            })
            if max_size_str.isdigit() or (max_size_str.startswith("-") and max_size_str[1:].isdigit()):
                mssql_instance["max_size"] = float(max_size_str) * 1024 * 1024
            if allocated_size_str.isdigit() or (allocated_size_str.startswith("-") and allocated_size_str[1:].isdigit()):
                mssql_instance["allocated_size"] = float(allocated_size_str) * 1024 * 1024
            if used_size_str.isdigit() or (used_size_str.startswith("-") and used_size_str[1:].isdigit()):
                mssql_instance["used_size"] = float(used_size_str) * 1024 * 1024

        summarize = params.get("summarize_transactionlogs", False)
        out = []
        for key in section:
            inst, database, file_name = key
            item = _format_item_mssql_datafiles(inst, database, None if summarize else file_name)
            out.append({"item": item, "params": {"used_levels": (80.0, 90.0)}, "metrics": ["data_size", "allocated_size", "allocated_used"]})
        return {"changed": False, "msg": "discovered %d transactionlogs" % len(out),
                "data": {"discovery": out}}

    # Check mode: one item
    res = ctx.run(["cat", "/var/lib/mk-transactionlogs"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read transactionlogs agent section",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    section = {}
    for line in lines:
        fields = line.split("\t")
        if len(fields) != 6 and len(fields) != 8:
            continue
        if fields[-1].startswith("ERROR: "):
            continue
        if len(fields) == 6:
            inst = None
            database = fields[0]
            file_name = fields[1]
            physical_name = fields[2]
            max_size_str = fields[3]
            allocated_size_str = fields[4]
            used_size_str = fields[5]
            unlimited = False
        else:
            inst = fields[0]
            database = fields[1]
            file_name = fields[2]
            physical_name = fields[3]
            max_size_str = fields[4]
            allocated_size_str = fields[5]
            used_size_str = fields[6]
            unlimited = fields[7] == "1"
        key = (inst, database, file_name)
        mssql_instance = section.setdefault(key, {
            "unlimited": unlimited,
            "max_size": None,
            "allocated_size": None,
            "used_size": None,
            "mountpoint": physical_name.lower()
        })
        if max_size_str.isdigit() or (max_size_str.startswith("-") and max_size_str[1:].isdigit()):
            mssql_instance["max_size"] = float(max_size_str) * 1024 * 1024
        if allocated_size_str.isdigit() or (allocated_size_str.startswith("-") and allocated_size_str[1:].isdigit()):
            mssql_instance["allocated_size"] = float(allocated_size_str) * 1024 * 1024
        if used_size_str.isdigit() or (used_size_str.startswith("-") and used_size_str[1:].isdigit()):
            mssql_instance["used_size"] = float(used_size_str) * 1024 * 1024

    item = params.get("item", "")
    if len(section) == 0:
        return {"changed": False, "msg": "no data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    instances_for_item = []
    for key in section:
        inst, database, file_name = key
        key_item = _format_item_mssql_datafiles(inst, database, file_name)
        key_item_sum = _format_item_mssql_datafiles(inst, database, None)
        if key_item == item or key_item_sum == item:
            instances_for_item.append(section[key])

    if len(instances_for_item) == 0:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read df section data
    res_df = ctx.run(["df", "-Pk"], mutates=False)
    df_dict = {}
    if res_df.rc == 0:
        for line in res_df.stdout.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 6:
                mount = parts[5].rstrip("/")
                if parts[3].isdigit():
                    avail_mb = float(parts[3])
                    df_dict[mount] = {"avail_mb": avail_mb}

    available_bytes = {}
    for mount in df_dict:
        available_bytes[mount] = df_dict[mount]["avail_mb"] * 1024 * 1024

    usage = _datafile_usage(instances_for_item, available_bytes)

    # Process levels
    params_map = params
    used_levels_raw = params_map.get("used_levels", (80.0, 90.0))
    allocated_used_levels_raw = params_map.get("allocated_used_levels", (None, None))
    allocated_levels_raw = params_map.get("allocated_levels", (None, None))

    acc_state = {"value": "OK"}

    def calculate_levels(levels, reference_value):
        if isinstance(levels[0], float):
            if reference_value != None and reference_value != 0:
                warn = levels[0] * reference_value / 100.0
                crit = levels[1] * reference_value / 100.0
                return (warn, crit)
        elif levels[0] != None:
            warn = levels[0] * 1024 * 1024
            crit = levels[1] * 1024 * 1024
            return (warn, crit)
        return None

    def check_levels(value, levels):
        if levels == None:
            return
        warn_val = levels[0]
        crit_val = levels[1]
        if value >= crit_val:
            acc_state["value"] = "CRIT"
        elif value >= warn_val and acc_state["value"] != "CRIT":
            acc_state["value"] = "WARN"

    # Used
    if isinstance(used_levels_raw, list):
        levels = None
        for level_set in used_levels_raw:
            if usage["max"] > level_set[0]:
                levels = calculate_levels(level_set[1], usage["max"])
                break
    else:
        levels = calculate_levels(used_levels_raw, usage["max"])
    check_levels(usage["used"], levels)

    # Allocated used
    if isinstance(allocated_used_levels_raw, list):
        levels = None
        for level_set in allocated_used_levels_raw:
            if usage["allocated"] > level_set[0]:
                levels = calculate_levels(level_set[1], usage["allocated"])
                break
    else:
        levels = calculate_levels(allocated_used_levels_raw, usage["allocated"])
    check_levels(usage["used"], levels)

    # Allocated
    if isinstance(allocated_levels_raw, list):
        levels = None
        for level_set in allocated_levels_raw:
            if usage["max"] > level_set[0]:
                levels = calculate_levels(level_set[1], usage["max"])
                break
    else:
        levels = calculate_levels(allocated_levels_raw, usage["max"])
    check_levels(usage["allocated"], levels)

    # Render bytes
    def render_bytes(b):
        if b >= 1024*1024*1024*1024:
            return "%f TB" % (b/(1024*1024*1024*1024))
        elif b >= 1024*1024*1024:
            return "%f GB" % (b/(1024*1024*1024))
        elif b >= 1024*1024:
            return "%f MB" % (b/(1024*1024))
        elif b >= 1024:
            return "%f KB" % (b/1024)
        return "%f B" % b

    msg_parts = []
    if usage["used"] != None:
        msg_parts.append("Used: " + render_bytes(usage["used"]))
    if usage["allocated"] != None:
        msg_parts.append("Allocated: " + render_bytes(usage["allocated"]))
    msg_parts.append("Maximum size: " + render_bytes(usage["max"]))

    metrics = {
        "data_size": usage["used"],
        "allocated_size": usage["allocated"],
        "allocated_used": usage["used"]
    }

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": acc_state["value"],
            "metrics": metrics,
            "details": ""
        }
    }