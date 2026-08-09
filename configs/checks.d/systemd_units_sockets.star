def _pow(b, e):
    result = 1
    i = 0
    while i < e:
        result = result * b
        i = i + 1
    return result


def _parse_mem(raw):
    raw = raw.strip()
    if not raw:
        return None
    unit = "B"
    digits = ""
    i = 0
    while i < len(raw) and (raw[i:i+1].isdigit() or raw[i:i+1] == "."):
        digits = digits + raw[i]
        i = i + 1
    if i < len(raw):
        unit = raw[i:i+1].upper()
    mult = {"B": 1, "K": 1024, "M": 1024*1024, "G": 1024*1024*1024, "T": 1024*1024*1024*1024}
    return int(float(digits) * mult.get(unit, 1))


def _parse_cpu_ns(raw):
    if raw == None:
        return None
    raw = raw.strip()
    if not raw:
        return None
    if not raw.lstrip("-").isdigit():
        return None
    v = int(raw)
    if v == _UINT64_MAX:
        return None
    return v


def _parse_tasks(raw):
    if raw == None:
        return None
    raw = raw.strip()
    if not raw:
        return None
    if not raw.lstrip("-").isdigit():
        return None
    v = int(raw)
    if v == _UINT64_MAX:
        return None
    return v


_UINT64_MAX = _pow(2, 64) - 1

_STATUS_SYMBOLS = ("●", "○", "↻", "×", "x", "*")


def _iter_show_blocks(stdout):
    blocks = []
    current = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            if current:
                blocks.append(current)
                current = {}
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            current[k] = v
    if current:
        blocks.append(current)
    return blocks


def _gather_units(ctx):
    services = {}
    sockets = {}
    res = ctx.run(
        ["systemctl", "list-units", "--all", "--type", "service", "--type", "socket",
         "--no-legend", "--no-pager"],
        mutates=False)
    if res.rc != 0 or not res.stdout:
        return services, sockets
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        if parts[0] in _STATUS_SYMBOLS:
            parts = parts[1:]
        if len(parts) < 4:
            continue
        unit_id = parts[0]
        if unit_id.endswith(".service"):
            unit_type = "service"
            name = unit_id[:-len(".service")]
        elif unit_id.endswith(".socket"):
            unit_type = "socket"
            name = unit_id[:-len(".socket")]
        else:
            continue
        loaded_status = parts[1]
        active_status = parts[2]
        current_state = parts[3]
        description = " ".join(parts[4:]) if len(parts) > 4 else ""
        entry = {
            "name": name,
            "loaded_status": loaded_status,
            "active_status": active_status,
            "current_state": current_state,
            "description": description,
            "enabled_status": None,
            "memory": None,
            "cpu_seconds": None,
            "number_of_tasks": None,
        }
        if unit_type == "service":
            services[name] = entry
        else:
            sockets[name] = entry
    all_names = []
    for e in services.values():
        all_names.append(e["name"] + ".service")
    for e in sockets.values():
        all_names.append(e["name"] + ".socket")
    if all_names:
        show = ctx.run(
            ["systemctl", "show"] + all_names +
            ["--property=Id,UnitFileState,MemoryCurrent,CPUUsageNSec,TasksCurrent"],
            mutates=False)
        if show.rc == 0 and show.stdout:
            for block in _iter_show_blocks(show.stdout):
                uid = block.get("Id")
                if uid == None:
                    continue
                if uid.endswith(".service"):
                    name = uid[:-len(".service")]
                    target = services
                elif uid.endswith(".socket"):
                    name = uid[:-len(".socket")]
                    target = sockets
                else:
                    continue
                if name not in target:
                    continue
                entry = target[name]
                entry["enabled_status"] = block.get("UnitFileState") or None
                mem = block.get("MemoryCurrent")
                if mem != None:
                    m = _parse_mem(mem)
                    entry["memory"] = m
                cpu = block.get("CPUUsageNSec")
                entry["cpu_seconds"] = _parse_cpu_ns(cpu)
                tasks = block.get("TasksCurrent")
                entry["number_of_tasks"] = _parse_tasks(tasks)
    listf = ctx.run(
        ["systemctl", "list-unit-files", "--type", "service", "--type", "socket",
         "--no-legend", "--no-pager"],
        mutates=False)
    if listf.rc == 0 and listf.stdout:
        for line in listf.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            uid = parts[0]
            state = parts[1]
            if uid.endswith(".service"):
                name = uid[:-len(".service")]
                if name in services:
                    if services[name]["enabled_status"] in (None, ""):
                        services[name]["enabled_status"] = state
                else:
                    services[name] = {"name": name, "enabled_status": state,
                                      "loaded_status": "", "active_status": "",
                                      "current_state": "", "description": "",
                                      "memory": None, "cpu_seconds": None,
                                      "number_of_tasks": None}
            elif uid.endswith(".socket"):
                name = uid[:-len(".socket")]
                if name in sockets:
                    if sockets[name]["enabled_status"] in (None, ""):
                        sockets[name]["enabled_status"] = state
                else:
                    sockets[name] = {"name": name, "enabled_status": state,
                                     "loaded_status": "", "active_status": "",
                                     "current_state": "", "description": "",
                                     "memory": None, "cpu_seconds": None,
                                     "number_of_tasks": None}
    return services, sockets


def _is_skipped(name):
    if name.startswith("check-mk-agent@"):
        return True
    return False


def _grade_state(state_str, states_map, default_state):
    if state_str in states_map:
        return states_map[state_str]
    return default_state


_STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}


def _state_name(code):
    n = _STATE_NAMES.get(code)
    if n == None:
        return "UNKNOWN"
    return n


def main(ctx, params):
    if params.get("_discover"):
        services, sockets = _gather_units(ctx)
        if not services and not sockets:
            return {"changed": False, "msg": "systemd not available",
                    "data": {"discovery": []}}
        discovery = []
        for name in sorted(sockets.keys()):
            entry = sockets[name]
            if _is_skipped(name):
                continue
            discovery.append({
                "item": name,
                "params": {
                    "states": {"active": 0, "inactive": 0, "failed": 2},
                    "states_default": 2,
                    "else": 2,
                },
                "metrics": ["memory_used", "cpu_time", "number_of_tasks", "active_since"],
                "service_labels": {
                    "cmk/systemd/unit_type": "socket",
                    "cmk/systemd/enabled": entry["enabled_status"] or "",
                    "cmk/systemd/loaded": entry["loaded_status"],
                },
            })
        return {"changed": False,
                "msg": "discovered %d socket units" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    services, sockets = _gather_units(ctx)
    if not services and not sockets:
        return {"changed": False, "msg": "systemd not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item not in sockets:
        return {"changed": False, "msg": "Unit not found",
                "data": {"state": "UNKNOWN",
                         "details": "Only units currently in memory are found.",
                         "metrics": {}}}
    unit = sockets[item]
    states_map_raw = params.get("states", {"active": 0, "inactive": 0, "failed": 2})
    states_map = {}
    if type(states_map_raw) == "dict":
        states_map = states_map_raw
    states_default = params.get("states_default", 2)
    code = _grade_state(unit["active_status"], states_map, states_default)
    state_str = _state_name(code)
    metrics = {}
    if unit["memory"] != None:
        metrics["memory_used"] = unit["memory"]
    if unit["cpu_seconds"] != None:
        metrics["cpu_time"] = unit["cpu_seconds"]
    if unit["number_of_tasks"] != None:
        metrics["number_of_tasks"] = unit["number_of_tasks"]
    details = "Status: %s\nDescription: %s\nEnabled: %s\nLoaded: %s" % (
        unit["active_status"],
        unit["description"],
        unit["enabled_status"] or "unknown",
        unit["loaded_status"],
    )
    if unit["memory"] != None:
        details = details + "\nMemory: %d bytes" % unit["memory"]
    if unit["cpu_seconds"] != None:
        details = details + "\nCPU Time: %s s" % unit["cpu_seconds"]
    if unit["number_of_tasks"] != None:
        details = details + "\nTasks: %d" % unit["number_of_tasks"]
    return {"changed": False,
            "msg": "Status: %s" % unit["active_status"],
            "data": {"state": state_str, "metrics": metrics, "details": details}}