def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check-mk-agent/openhardwaremonitor"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "agent data unavailable", "data": {"discovery": []}}
        section = _parse_section(res.stdout.splitlines())
        items = list(section.get("Fan", {}).keys())
        discovery = [{"item": item, "params": {}, "metrics": ["fan"]} for item in items]
        return {"changed": False, "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/openhardwaremonitor"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "agent data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_section(res.stdout.splitlines())
    if item not in section.get("Fan", {}):
        return {"changed": False, "msg": "fan not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = section["Fan"][item]
    if data["WMIstatus"].lower() == "timeout":
        return {"changed": False, "msg": "WMI query timed out",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    fan_rpm = data["reading"]
    warn = params.get("lower", [0, 0])[0] if params.get("lower") else 0
    crit = params.get("lower", [0, 0])[1] if params.get("lower") else 0
    state = "CRIT" if fan_rpm <= crit else ("WARN" if fan_rpm <= warn else "OK")
    msg = "%d RPM" % int(fan_rpm)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"fan": fan_rpm}, "details": ""}}


def _parse_section(lines):
    parsed = {}
    for line in lines:
        parts = line.split(",")
        if len(parts) == 0 or parts[0] == "Index":
            continue
        if len(parts) == 5:
            index, name, parent, sensor_type, value = parts
            wmistatus = "OK"
        elif len(parts) == 6:
            index, name, parent, sensor_type, value, wmistatus = parts
        else:
            continue
        full_name = _full_name(parent, name)
        traits = _TRAITS.get(sensor_type, {"unit": "", "factor": 1.0})
        value_num = float(value) * traits["factor"]
        parsed.setdefault(sensor_type, {})[full_name] = {
            "reading": value_num,
            "unit": traits["unit"],
            "perf_var": traits.get("perf_var"),
            "WMIstatus": wmistatus,
        }
    return parsed


_TRAITS = {
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


def _full_name(parent, name):
    replacements = {
        "intelcpu": "cpu",
        "amdcpu": "cpu",
        "genericcpu": "cpu",
    }
    for k, v in replacements.items():
        parent = parent.replace("/" + k + "/", "/" + v + "/")
    name = name.replace("CPU ", "").replace("Temperature", "")
    return (parent.replace("/", "") + " " + name).strip()
