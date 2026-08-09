def _full_name(parent, name):
    def replace(text, reps):
        out = text
        for k in reps:
            out = out.replace(k, reps[k])
        return out
    p = replace(parent, {"intelcpu": "cpu", "amdcpu": "cpu", "genericcpu": "cpu"})
    n = replace(name, {"CPU ": "", "Temperature": ""})
    return (p.replace("/", "") + " " + n).strip()

def _parse_section(rows):
    parsed = {}
    for line in rows:
        if line[0] == "Index":
            continue
        n = len(line)
        if n == 5:
            idx, name, parent, stype, value = line
            wmi = "OK"
        elif n == 6:
            idx, name, parent, stype, value, wmi = line
        else:
            continue
        traits = {"Clock": {"unit": " MHz", "factor": 1.0, "perf_var": "clock"},
                  "Temperature": {"unit": "°C", "factor": 1.0, "perf_var": None},
                  "Power": {"unit": " W", "factor": 1.0, "perf_var": "w"},
                  "Fan": {"unit": " RPM", "factor": 1.0, "perf_var": None},
                  "Level": {"unit": "%", "factor": 1.0, "perf_var": None},
                  "Voltage": {"unit": " V", "factor": 1.0, "perf_var": None},
                  "Load": {"unit": "%", "factor": 1.0, "perf_var": None},
                  "Flow": {"unit": " L/h", "factor": 1.0, "perf_var": None},
                  "Control": {"unit": "%", "factor": 1.0, "perf_var": None},
                  "Factor": {"unit": "1", "factor": 1.0, "perf_var": None},
                  "Data": {"unit": " B", "factor": 1073741824.0, "perf_var": None}}
    t = traits.get(stype, {"unit": "", "factor": 1.0, "perf_var": None})
    fn = _full_name(parent, name)
    factor = t.get("factor", 1.0)
    val = float(value) * factor
    parsed.setdefault(stype, {})[fn] = {"reading": val, "unit": t.get("unit", ""),
        "perf_var": t.get("perf_var"), "wmi": wmi}
    return parsed

def _expect_order(a, b, c):
    arglist = [x for x in [a, b, c] if x != None]
    pairs = sorted(enumerate(arglist), key=lambda x: x[1])
    distance = 0
    for i, p in enumerate(pairs):
        d = abs(i - p[0])
        if d > distance:
            distance = d
    m = {0: "OK", 1: "WARN", 2: "CRIT"}
    return m.get(distance, "UNKNOWN")

def _check_power(sensor_type, item, params, section):
    if item not in section.get(sensor_type, {}):
        return {"state": "UNKNOWN", "summary": "item not found"}
    data = section[sensor_type][item]
    if data["wmi"].lower() == "timeout":
        return {"state": "UNKNOWN", "summary": "WMI query timed out"}
    state_lower = "OK"
    if "lower" in params:
        state_lower = _expect_order(params["lower"][1], params["lower"][0], data["reading"])
    state_upper = "OK"
    if "upper" in params:
        state_upper = _expect_order(data["reading"], params["upper"][0], params["upper"][1])
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    for s in [state_lower, state_upper]:
        if order[s] > order[worst]:
            worst = s
    return {"state": worst, "summary": "%f%s" % (data["reading"], data["unit"]),
            "perf_var": data["perf_var"], "reading": data["reading"]}

def _get_rows(ctx):
    res = ctx.run(["openhardwaremonitor", "--export", "--format", "csv"], mutates=False)
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    rows = []
    for line in lines:
        cols = line.split(",")
        if len(cols) >= 5:
            rows.append(cols)
    return rows

def main(ctx, params):
    if params.get("_discover"):
        rows = _get_rows(ctx)
        if rows == None or len(rows) == 0:
            return {"changed": False, "msg": "no openhardwaremonitor data",
                    "data": {"discovery": []}}
        section = _parse_section(rows)
        out = []
        for item in section.get("Power", {}):
            out.append({"item": item, "params": {}, "metrics": ["w"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    rows = _get_rows(ctx)
    if rows == None or len(rows) == 0:
        return {"changed": False, "msg": "openhardwaremonitor not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_section(rows)
    res = _check_power("Power", item, params, section)
    metrics = {}
    if res["perf_var"] != None:
        metrics[res["perf_var"]] = res["reading"]
    return {"changed": False, "msg": res["summary"],
            "data": {"state": res["state"], "metrics": metrics, "details": ""}}