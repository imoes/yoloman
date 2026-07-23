SMART_READINGS = [
    {"name": "Remaining Life", "key": "remaining_life", "lower_bounds": True},
]

def _clean_parent(p):
    p = p.replace("intelcpu", "cpu")
    p = p.replace("amdcpu", "cpu")
    p = p.replace("genericcpu", "cpu")
    return p

def _clean_name(n):
    n = n.replace("CPU ", "")
    n = n.replace("Temperature", "")
    return n

def _full_name(parent, name):
    p = _clean_parent(parent).replace("/", "")
    n = _clean_name(name).strip()
    return (p + " " + n).strip()

def _to_float(s):
    s = s.strip()
    t = s[1:] if s.startswith("-") else s
    check = t.replace(".", "", 1)
    if len(check) > 0 and check.isdigit():
        return float(s)
    return 0.0

def _state_lower(crit, warn, reading):
    if reading >= warn:
        return "OK"
    if reading >= crit:
        return "WARN"
    return "CRIT"

def _state_upper(reading, warn, crit):
    if reading < warn:
        return "OK"
    if reading < crit:
        return "WARN"
    return "CRIT"

def _query_sensors(ctx):
    ps_cmd = (
        "Get-WmiObject -Namespace root/OpenHardwareMonitor -Class Sensor | " +
        "ForEach-Object { $_.SensorType + [char]9 + $_.Parent + [char]9 + $_.Name + [char]9 + $_.Value }"
    )
    return ctx.run(
        ["powershell", "-NoProfile", "-Command", ps_cmd],
        mutates=False,
        ok_codes=[0, 1],
    )

def _parse_sensors(stdout):
    sensors = {}
    for line in stdout.splitlines():
        parts = line.strip().split("\t")
        if len(parts) < 4:
            continue
        sensor_type = parts[0].strip()
        parent = parts[1].strip()
        name = parts[2].strip()
        value_str = parts[3].strip()
        if not sensor_type:
            continue
        fn = _full_name(parent, name)
        reading = _to_float(value_str)
        if sensor_type not in sensors:
            sensors[sensor_type] = {}
        sensors[sensor_type][fn] = reading
    return sensors

def main(ctx, params):
    if params.get("_discover"):
        res = _query_sensors(ctx)
        if not res.stdout.strip():
            return {
                "changed": False,
                "msg": "OpenHardwareMonitor not available",
                "data": {"discovery": []},
            }
        sensors = _parse_sensors(res.stdout)
        seen = {}
        for fn in sensors.get("Level", {}):
            if "hdd" in fn:
                dev = fn.split(" ")[0]
                seen[dev] = True
        discovery = []
        for dev in sorted(seen.keys()):
            discovery.append({
                "item": dev,
                "params": {"remaining_life": [30.0, 10.0]},
                "metrics": ["remaining_life"],
            })
        return {
            "changed": False,
            "msg": "discovered %d SMART devices" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    rl_levels = params.get("remaining_life", [30.0, 10.0])
    warn = float(rl_levels[0])
    crit = float(rl_levels[1])

    res = _query_sensors(ctx)
    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "OpenHardwareMonitor not available for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensors = _parse_sensors(res.stdout)
    msgs = []
    metrics = {}
    worst = "OK"

    for reading in SMART_READINGS:
        rname = item + " " + reading["name"]
        level_map = sensors.get("Level", {})
        if rname not in level_map:
            continue
        value = level_map[rname]
        if reading["lower_bounds"]:
            state = _state_lower(crit, warn, value)
        else:
            state = _state_upper(value, warn, crit)
        msgs.append("%s %f%%" % (reading["name"], value))
        metrics[reading["key"]] = value
        if state == "CRIT":
            worst = "CRIT"
        elif state == "WARN" and worst != "CRIT":
            worst = "WARN"

    if not msgs:
        return {
            "changed": False,
            "msg": "No SMART data for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": ", ".join(msgs),
        "data": {"state": worst, "metrics": metrics, "details": ""},
    }