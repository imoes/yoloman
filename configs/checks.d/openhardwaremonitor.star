TRAITS = {
    "Clock": {"unit": " MHz", "factor": 1.0, "perf_var": "clock"},
    "Temperature": {"unit": "°C", "factor": 1.0},
    "Power": {"unit": " W", "factor": 1.0, "perf_var": "w"},
    "Fan": {"unit": " RPM", "factor": 1.0},
    "Level": {"unit": "%", "factor": 1.0},
    "Voltage": {"unit": " V", "factor": 1.0},
    "Load": {"unit": "%", "factor": 1.0},
    "Flow": {"unit": " L/h", "factor": 1.0},
    "Control": {"unit": "%", "factor": 1.0},
    "Factor": {"unit": "1", "factor": 1.0},
    "Data": {"unit": " B", "factor": 1073741824.0},
}

REPLACEMENTS = {"intelcpu": "cpu", "amdcpu": "cpu", "genericcpu": "cpu"}

def _dict_replace(input_str, replacements):
    result = input_str
    for old, new in replacements.items():
        result = result.replace(old, new)
    return result

def _full_name(parent, name):
    parent = _dict_replace(parent, REPLACEMENTS)
    name = _dict_replace(name, {"CPU ": "", "Temperature": ""})
    return (parent.replace("/", "") + " " + name).strip()

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["curl", "-fsS", "http://localhost:8085/"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "openhardwaremonitor not available",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        if not lines:
            return {"changed": False, "msg": "no openhardwaremonitor data",
                    "data": {"discovery": []}}
        header = lines[0].split(",")
        if "Index" not in header:
            return {"changed": False, "msg": "unexpected openhardwaremonitor format",
                    "data": {"discovery": []}}
        out = []
        for line in lines[1:]:
            fields = line.split(",")
            if len(fields) < 5:
                continue
            if fields[0] == "Index":
                continue
            name = fields[1]
            parent = fields[2]
            sensor_type = fields[3]
            if sensor_type != "Clock":
                continue
            full_name = _full_name(parent, name)
            out.append({"item": full_name, "params": {"warn": 0, "crit": 0},
                        "metrics": ["clock"]})
        return {"changed": False, "msg": "discovered %d clock sensors" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["curl", "-fsS", "http://localhost:8085/"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "openhardwaremonitor not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    if not lines:
        return {"changed": False, "msg": "no data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = None
    unit = " MHz"
    for line in lines[1:]:
        fields = line.split(",")
        if len(fields) < 5:
            continue
        if fields[0] == "Index":
            continue
        name = fields[1]
        parent = fields[2]
        sensor_type = fields[3]
        if sensor_type != "Clock":
            continue
        full_name = _full_name(parent, name)
        if full_name == item:
            value_str = fields[4]
            reading = float(value_str)
            break

    if reading == None:
        return {"changed": False, "msg": "no such clock sensor: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("warn", 0)
    crit = params.get("crit", 0)
    state = "OK"
    if crit != 0 and reading >= crit:
        state = "CRIT"
    elif warn != 0 and reading >= warn:
        state = "WARN"
    msg = "%s %f%s" % (item, reading, unit)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"clock": reading}, "details": ""}}