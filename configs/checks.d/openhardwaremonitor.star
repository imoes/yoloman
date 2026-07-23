PARENT_SUBST = [
    ["intelcpu", "cpu"],
    ["amdcpu", "cpu"],
    ["genericcpu", "cpu"],
]

NAME_REMOVALS = ["CPU ", "Temperature"]

STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _normalize_parent(parent):
    result = parent
    for pair in PARENT_SUBST:
        result = result.replace(pair[0], pair[1])
    return result

def _normalize_name(name):
    result = name
    for removal in NAME_REMOVALS:
        result = result.replace(removal, "")
    return result

def _make_full_name(parent, name):
    p = _normalize_parent(parent).replace("/", "")
    n = _normalize_name(name)
    return (p + " " + n).strip()

def _worst(a, b):
    if STATE_ORDER.get(a, 0) >= STATE_ORDER.get(b, 0):
        return a
    return b

def _threshold_state(reading, params):
    state = "OK"
    lower = params.get("lower")
    upper = params.get("upper")
    if lower != None:
        if reading < lower[1]:
            state = _worst(state, "CRIT")
        elif reading < lower[0]:
            state = _worst(state, "WARN")
    if upper != None:
        if reading >= upper[1]:
            state = _worst(state, "CRIT")
        elif reading >= upper[0]:
            state = _worst(state, "WARN")
    return state

def _query_sensors(ctx):
    cmd = (
        "Get-WmiObject -Namespace root\\OpenHardwareMonitor -Class Sensor" +
        " | Select-Object Index,Name,Parent,SensorType,Value" +
        " | ConvertTo-Json -Compress"
    )
    res = ctx.run(["powershell", "-NonInteractive", "-Command", cmd], mutates=False)
    if res.rc != 0:
        return None, "WMI query failed (rc=%d): %s" % (res.rc, res.stderr.strip())
    raw = res.stdout.strip()
    if not raw or raw == "null":
        return [], ""
    data = json.decode(raw)
    if data == None:
        return [], ""
    if type(data) == "dict":
        data = [data]
    return data, ""

def main(ctx, params):
    if params.get("_discover"):
        sensors, err = _query_sensors(ctx)
        if sensors == None:
            return {
                "changed": False,
                "msg": err,
                "data": {"discovery": []},
            }
        items = []
        seen = {}
        for s in sensors:
            if s.get("SensorType") != "Clock":
                continue
            parent = s.get("Parent", "")
            name = s.get("Name", "")
            full_name = _make_full_name(parent, name)
            if seen.get(full_name) == None:
                seen[full_name] = True
                items.append({
                    "item": full_name,
                    "params": {},
                    "metrics": ["clock"],
                })
        return {
            "changed": False,
            "msg": "discovered %d clock sensors" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    sensors, err = _query_sensors(ctx)

    if sensors == None:
        return {
            "changed": False,
            "msg": err,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": err},
        }

    target = None
    for s in sensors:
        if s.get("SensorType") != "Clock":
            continue
        parent = s.get("Parent", "")
        name = s.get("Name", "")
        full_name = _make_full_name(parent, name)
        if full_name == item:
            target = s
            break

    if target == None:
        return {
            "changed": False,
            "msg": "Clock sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    reading = float(target.get("Value", 0))
    state = _threshold_state(reading, params)

    return {
        "changed": False,
        "msg": "%f MHz" % reading,
        "data": {
            "state": state,
            "metrics": {"clock": reading},
            "details": "",
        },
    }