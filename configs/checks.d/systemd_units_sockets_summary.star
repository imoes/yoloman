def main(ctx, params):
    # Both discovery and check mode use the same systemd data
    # Command to list all sockets with detailed status
    res = ctx.run([
        "bash", "-c",
        "systemctl list-units --type=socket --all --no-pager --no-legend 2>/dev/null && echo \"[status]\" && systemctl show --type=socket --all --no-pager 2>/dev/null"
    ], mutates=False)

    lines = res.stdout.splitlines()
    if not lines:
        return {"changed": False, "msg": "no systemd data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the combined output: list-units output followed by [status] and show output
    # We'll split by the [status] marker to separate the two sections
    idx = -1
    for i in range(len(lines)):
        if lines[i].strip() == "[status]":
            idx = i
            break

    if idx == -1:
        # No [status] marker, try legacy format (just list-units)
        unit_lines = lines
        show_lines = []
    else:
        unit_lines = lines[:idx]
        show_lines = lines[idx+1:]

    # Parse list-units output to get basic socket info
    # Format: UNIT LOAD ACTIVE SUB DESCRIPTION
    sockets_list = {}
    for line in unit_lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Strip leading status glyph if present
        if stripped[0] in "●○↻×x*":
            stripped = stripped[1:]
        parts = stripped.split(None, 4)
        if len(parts) < 5:
            continue
        unit_name = parts[0]
        # Extract name without .socket suffix
        if unit_name.endswith(".socket"):
            name = unit_name[:-7]
        else:
            continue

        loaded_status = parts[1]
        active_status = parts[2]
        sub_state = parts[3]
        description = parts[4] if len(parts) > 4 else ""
        sockets_list[name] = {
            "name": name,
            "loaded_status": loaded_status,
            "active_status": active_status,
            "sub_state": sub_state,
            "description": description,
        }

    # Parse show output to get detailed info (CPU, Memory, etc)
    sockets_show = {}
    current_unit = {}
    for line in show_lines:
        if not line.strip():
            if current_unit and "Id" in current_unit:
                unit_id = current_unit.get("Id", "")
                if unit_id.endswith(".socket"):
                    name = unit_id[:-7]
                    sockets_show[name] = current_unit.copy()
            current_unit = {}
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            current_unit[key] = value

    # Final cleanup for last unit
    if current_unit and "Id" in current_unit:
        unit_id = current_unit.get("Id", "")
        if unit_id.endswith(".socket"):
            name = unit_id[:-7]
            sockets_show[name] = current_unit.copy()

    # Merge the two data sources: use show data when available, otherwise list data
    for name, data in sockets_show.items():
        if name in sockets_list:
            # Merge show data into list data
            sockets_list[name].update({
                "cpu": data.get("CPUUsageNSec"),
                "memory": data.get("MemoryCurrent"),
                "tasks": data.get("TasksCurrent"),
                "state_change": data.get("StateChangeTimestampMonotonic"),
                "active_state": data.get("ActiveState"),
                "sub_state": data.get("SubState"),
            })
        else:
            sockets_list[name] = {
                "name": name,
                "loaded_status": data.get("LoadState", "not-found"),
                "active_status": data.get("ActiveState", "inactive"),
                "sub_state": data.get("SubState", ""),
                "description": data.get("Description", ""),
                "cpu": data.get("CPUUsageNSec"),
                "memory": data.get("MemoryCurrent"),
                "tasks": data.get("TasksCurrent"),
                "state_change": data.get("StateChangeTimestampMonotonic"),
                "enabled_status": data.get("UnitFileState"),
            }

    # Check discovery mode
    if params.get("_discover"):
        if not sockets_list:
            return {"changed": False, "msg": "no sockets found", "data": {"discovery": []}}

        discovery_list = []
        for name in sockets_list:
            discovery_list.append({
                "item": name,
                "params": {"states": {"active": 0, "inactive": 0, "failed": 2}, "states_default": 2, "ignored": []},
                "metrics": ["cpu_time", "mem_used", "number_of_tasks"]
            })

        return {"changed": False, "msg": "discovered %d sockets" % len(sockets_list),
                "data": {"discovery": discovery_list}}

    # Check mode: single item
    item = params.get("item", "")
    if item not in sockets_list:
        return {"changed": False, "msg": "socket '%s' not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    socket = sockets_list[item]
    active_status = socket.get("active_status", "inactive")

    # Determine state
    states = params.get("states", {"active": 0, "inactive": 0, "failed": 2})
    default_state = params.get("states_default", 2)
    state_code = states.get(active_status, default_state)
    state_names = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state = state_names.get(state_code, "UNKNOWN")

    # Build summary message
    msg_parts = ["Status: " + active_status]
    if socket.get("description"):
        msg_parts.append(socket.get("description"))

    # Calculate metrics if available
    metrics = {}

    # CPU time (CPUUsageNSec)
    cpu_raw = socket.get("cpu")
    if cpu_raw and cpu_raw.isdigit():
        cpu_ns = int(cpu_raw)
        if cpu_ns != 18446744073709551615:  # 2**64 - 1 sentinel
            cpu_sec = cpu_ns / 1.0e9
            metrics["cpu_time"] = cpu_sec

    # Memory (MemoryCurrent)
    mem_raw = socket.get("memory")
    if mem_raw and mem_raw.isdigit():
        mem_bytes = int(mem_raw)
        if mem_bytes != 18446744073709551615:  # 2**64 - 1 sentinel
            metrics["mem_used"] = mem_bytes

    # Number of tasks
    tasks_raw = socket.get("tasks")
    if tasks_raw and tasks_raw.isdigit():
        tasks = int(tasks_raw)
        if tasks != 18446744073709551615:  # 2**64 - 1 sentinel
            metrics["number_of_tasks"] = tasks

    details = ""
    return {"changed": False, "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": details}}