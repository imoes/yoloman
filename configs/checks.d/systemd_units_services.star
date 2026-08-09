SYSTEMD_UNIT_SUFFIXES = ["service", "socket"]

# systemctl list-unit-files recognized "LoadState" file states
_SYSTEMD_UNIT_FILE_STATES = [
    "enabled",
    "enabled-runtime",
    "linked",
    "linked-runtime",
    "masked",
    "masked-runtime",
    "static",
    "indirect",
    "disabled",
    "generated",
    "transient",
    "bad",
]

# default check states mapping (Checkmk defaults)
_DEFAULT_STATES = {"active": 0, "inactive": 0, "failed": 2}
_DEFAULT_STATES_DEFAULT = 2
_DEFAULT_ELSE = 2

# skip the volatile Checkmk agent unit
_SKIPPED_PREFIX = "check-mk-agent@"


def _has_systemctl(ctx):
    res = ctx.run(["systemctl", "--version"], mutates=False)
    return res.rc != 127


def _list_units(ctx, unit_type):
    res = ctx.run(
        ["systemctl", "list-units", "--type=" + unit_type, "--all", "--no-legend", "--plain"],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 4:
            continue
        rows.append(f)
    return rows


def _unit_name_and_type(raw):
    for ut in SYSTEMD_UNIT_SUFFIXES:
        suffix = "." + ut
        if raw.endswith(suffix):
            return raw[:-len(suffix)], ut
    return None


def _show_unit(ctx, unit_name, unit_type):
    full = unit_name + "." + unit_type
    props = "Id,LoadState,ActiveState,SubState,Description,UnitFileState," + \
            "MemoryCurrent,CPUUsageNSec,TasksCurrent,StateChangeTimestampMonotonic"
    res = ctx.run(
        ["systemctl", "show", full, "--property=" + props],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return None
    block = {}
    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        block[key] = value
    return block


def _to_int(raw):
    if not raw:
        return None
    raw = raw.strip()
    if raw == "[not set]" or raw == "0":
        return None
    # handle negative sentinel (uint64 max / -1)
    if raw.startswith("-"):
        return None
    digits = raw.lstrip("-")
    if not digits.isdigit():
        return None
    val = int(raw)
    if val < 0:
        return None
    return val


def _to_float(raw):
    if not raw:
        return None
    raw = raw.strip()
    if not raw:
        return None
    parts = raw.split(".")
    ok = True
    for p in parts:
        if not p.isdigit():
            ok = False
            break
    if not ok:
        return None
    return float(raw)


def _uptime(ctx):
    res = ctx.run(["systemctl", "show", "-", "--property=ActiveEnterTimestampMonotonic"],
                  mutates=False)
    if res.rc == 0 and res.stdout.strip():
        for line in res.stdout.splitlines():
            if "=" in line:
                _, value = line.split("=", 1)
                v = _to_int(value.strip())
                if v != None:
                    return v / 1000000.0
    # fallback: read /proc/uptime
    if ctx.file_exists("/proc/uptime"):
        content = ctx.file_read("/proc/uptime")
        parts = content.split()
        v = _to_float(parts[0]) if len(parts) > 0 else None
        if v != None:
            return v
    return 0.0


def _discover(ctx, unit_type):
    if not _has_systemctl(ctx):
        return []
    uptime_seconds = _uptime(ctx)
    rows = _list_units(ctx, unit_type)
    entries = []
    for f in rows:
        unit_id = f[0].strip()
        if unit_id.startswith(_SKIPPED_PREFIX):
            continue
        name_type = _unit_name_and_type(unit_id)
        if name_type == None:
            continue
        name, ut = name_type
        if ut != unit_type:
            continue
        active_status = f[2]
        loaded_status = f[1]
        sub_state = f[3]
        block = _show_unit(ctx, name, unit_type)
        if block == None:
            entries.append({
                "name": name,
                "loaded": loaded_status,
                "active": active_status,
                "sub": sub_state,
                "description": "",
                "enabled": None,
                "memory": None,
                "cpu_seconds": None,
                "tasks": None,
                "time_since_change": None,
            })
        else:
            entries.append(_parse_show_block(block, uptime_seconds))
    return entries


def _parse_show_block(block, uptime_seconds):
    unit_id = block.get("Id", "")
    if not unit_id:
        return None
    name_type = _unit_name_and_type(unit_id)
    if name_type == None:
        return None

    memory = _to_int(block.get("MemoryCurrent"))
    cpu_ns = _to_int(block.get("CPUUsageNSec"))
    cpu_seconds = cpu_ns / 1000000000.0 if cpu_ns != None else None
    tasks = _to_int(block.get("TasksCurrent"))
    enabled = block.get("UnitFileState") or None
    if enabled and enabled not in _SYSTEMD_UNIT_FILE_STATES:
        enabled = None

    time_since_change = None
    sc = block.get("StateChangeTimestampMonotonic")
    ts_us = _to_int(sc)
    if ts_us != None and ts_us > 0:
        elapsed = uptime_seconds - ts_us / 1000000.0
        if elapsed >= 0:
            time_since_change = elapsed

    return {
        "name": block.get("Id", "")[:-len("." + name_type[1])] if name_type else "",
        "loaded": block.get("LoadState", ""),
        "active": block.get("ActiveState", ""),
        "sub": block.get("SubState", ""),
        "description": block.get("Description", ""),
        "enabled": enabled,
        "memory": memory,
        "cpu_seconds": cpu_seconds,
        "tasks": tasks,
        "time_since_change": time_since_change,
    }


def _match_regex(pattern, text):
    return False


def _grade_state(active_status, states, states_default):
    val = states.get(active_status, states_default)
    if val == 0:
        return "OK"
    if val == 1:
        return "WARN"
    return "CRIT"


def _check_levels(value, levels_upper, levels_lower):
    if value == None:
        return "OK", None
    if levels_upper:
        w = levels_upper[0]
        c = levels_upper[1]
        if value >= c:
            return "CRIT", value
        if value >= w:
            return "WARN", value
    if levels_lower:
        w = levels_lower[0]
        c = levels_lower[1]
        if value <= c:
            return "CRIT", value
        if value <= w:
            return "WARN", value
    return "OK", value


def _worst_state(states):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    for s in states:
        if order.get(s, 0) > order.get(worst, 0):
            worst = s
    return worst


def _match_rule(entry, names, descriptions, states):
    if names:
        hit = False
        for n in names:
            if n.startswith("~"):
                if _match_regex(n[1:], entry["name"]):
                    hit = True
                    break
            elif n == entry["name"]:
                hit = True
                break
        if not hit:
            return False
    if descriptions:
        hit = False
        for d in descriptions:
            if d.startswith("~"):
                if _match_regex(d[1:], entry["description"]):
                    hit = True
                    break
            elif d == entry["description"]:
                hit = True
                break
        if not hit:
            return False
    if states:
        if entry["active"] not in states:
            return False
    return True


def main(ctx, params):
    if params.get("_discover"):
        unit_type = params.get("unit_type", "service")
        names = params.get("names", [])
        descriptions = params.get("descriptions", [])
        states = params.get("states", [])

        entries = _discover(ctx, unit_type)
        out = []
        for entry in entries:
            if _match_rule(entry, names, descriptions, states):
                out.append({
                    "item": entry["name"],
                    "params": {},
                    "metrics": ["cpu_time", "mem_used", "number_of_tasks", "active_since"],
                })
        return {
            "changed": False,
            "msg": "discovered %d units" % len(out),
            "data": {"discovery": out},
        }

    unit_type = params.get("unit_type", "service")
    item = params.get("item", "")

    # A per-unit check with no item is a mis-assignment (the aggregate is
    # systemd_units_services_summary). Report UNKNOWN with guidance rather than a
    # false CRIT "Unit not found" — and skip the expensive full-unit scan below.
    if not item:
        return {
            "changed": False,
            "msg": "no unit specified",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "This per-unit check needs an 'item' (a specific unit). Assign it to a unit, or use systemd_units_services_summary for the aggregate.",
            },
        }

    if not _has_systemctl(ctx):
        return {
            "changed": False,
            "msg": "systemctl not found (systemd not running)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    uptime_seconds = _uptime(ctx)
    entries = _discover(ctx, unit_type)

    target = None
    for e in entries:
        if e["name"] == item:
            target = e
            break

    if target == None:
        else_state = params.get("else", _DEFAULT_ELSE)
        state = "OK" if else_state == 0 else ("WARN" if else_state == 1 else "CRIT")
        return {
            "changed": False,
            "msg": "Unit not found",
            "data": {
                "state": state,
                "metrics": {},
                "details": "Only units currently in memory are found. These can be shown with `systemctl --all --type service --type socket`.",
            },
        }

    states_map = params.get("states", _DEFAULT_STATES)
    states_default = params.get("states_default", _DEFAULT_STATES_DEFAULT)
    state = _grade_state(target["active"], states_map, states_default)

    metrics = {}
    details_parts = ["Status: %s" % target["active"]]
    verdict_states = [state]

    if target["cpu_seconds"] != None:
        cpu_levels = params.get("cpu_time")
        s, _ = _check_levels(target["cpu_seconds"], cpu_levels, None)
        if s != "OK":
            verdict_states.append(s)
        metrics["cpu_time"] = target["cpu_seconds"]
        details_parts.append("CPU Time: %fs" % target["cpu_seconds"])

    if target["time_since_change"] != None and target["active"] == "active":
        lower = params.get("active_since_lower")
        upper = params.get("active_since_upper")
        s, _ = _check_levels(target["time_since_change"], upper, lower)
        if s != "OK":
            verdict_states.append(s)
        metrics["active_since"] = target["time_since_change"]
        details_parts.append("Active since: %fs" % target["time_since_change"])

    if target["memory"] != None:
        mem_levels = params.get("memory")
        s, _ = _check_levels(target["memory"], mem_levels, None)
        if s != "OK":
            verdict_states.append(s)
        metrics["mem_used"] = target["memory"]
        details_parts.append("Memory: %d B" % target["memory"])

    if target["tasks"] != None:
        metrics["number_of_tasks"] = target["tasks"]
        details_parts.append("Tasks: %d" % target["tasks"])

    details_parts.append(target["description"])
    final_state = _worst_state(verdict_states)

    return {
        "changed": False,
        "msg": "%s (%s)" % (", ".join(details_parts[:2]), target["active"]),
        "data": {
            "state": final_state,
            "metrics": metrics,
            "details": ", ".join(details_parts),
        },
    }