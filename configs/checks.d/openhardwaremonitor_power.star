POWER_UNIT = " W"
POWER_PERF_VAR = "w"
STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

PS_CMD = (
    "ConvertTo-Json -Compress @(Get-WmiObject -Namespace root/OpenHardwareMonitor" +
    " -Class Sensor | Where-Object { $_.SensorType -eq 'Power' }" +
    " | Select-Object Name, Parent, Value)"
)

def _normalize_parent(parent):
    result = parent.replace("intelcpu", "cpu")
    result = result.replace("amdcpu", "cpu")
    result = result.replace("genericcpu", "cpu")
    return result

def _normalize_name(name):
    result = name.replace("CPU ", "")
    result = result.replace("Temperature", "")
    return result

def _full_name(parent, name):
    p = _normalize_parent(parent).replace("/", "")
    n = _normalize_name(name)
    return (p + " " + n).strip()

def _worst_state(a, b):
    if STATE_ORDER.get(b, 0) > STATE_ORDER.get(a, 0):
        return b
    return a

def _check_upper(reading, warn, crit):
    if reading >= crit:
        return "CRIT"
    if reading >= warn:
        return "WARN"
    return "OK"

def _check_lower(reading, warn, crit):
    if reading <= crit:
        return "CRIT"
    if reading <= warn:
        return "WARN"
    return "OK"

def _fetch_power_sensors(ctx):
    return ctx.run(["powershell", "-NoProfile", "-Command", PS_CMD], mutates=False)

def _parse_sensors(raw):
    text = raw.strip()
    if not text or text == "null":
        return []
    if text.startswith("["):
        return json.decode(text)
    if text.startswith("{"):
        return [json.decode(text)]
    return []

def main(ctx, params):
    if params.get("_discover"):
        res = _fetch_power_sensors(ctx)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "OpenHardwareMonitor WMI query failed",
                "data": {"discovery": []},
            }
        sensors = _parse_sensors(res.stdout)
        items = []
        for s in sensors:
            name = s.get("Name", "")
            parent = s.get("Parent", "")
            if name == "" or parent == "":
                continue
            item = _full_name(parent, name)
            items.append({
                "item": item,
                "params": {},
                "metrics": [POWER_PERF_VAR],
            })
        return {
            "changed": False,
            "msg": "discovered %d power sensors" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    res = _fetch_power_sensors(ctx)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "OpenHardwareMonitor WMI query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensors = _parse_sensors(res.stdout)
    reading = None
    for s in sensors:
        name = s.get("Name", "")
        parent = s.get("Parent", "")
        if _full_name(parent, name) == item:
            val = s.get("Value")
            if val != None:
                reading = float(val)
            break

    if reading == None:
        return {
            "changed": False,
            "msg": "power sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK"
    upper = params.get("upper")
    if upper != None:
        state = _worst_state(state, _check_upper(reading, float(upper[0]), float(upper[1])))

    lower = params.get("lower")
    if lower != None:
        state = _worst_state(state, _check_lower(reading, float(lower[0]), float(lower[1])))

    return {
        "changed": False,
        "msg": "%f%s" % (reading, POWER_UNIT),
        "data": {
            "state": state,
            "metrics": {POWER_PERF_VAR: reading},
            "details": "",
        },
    }