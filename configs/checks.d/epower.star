def main(ctx, params):
    if params.get("_discover"):
        data = _read_epower_data(ctx, params)
        if data == None:
            return {"changed": False, "msg": "no epower data source found",
                    "data": {"discovery": [],
                             "host_labels": {"cmk/epower": "absent"}}}
        discovery = []
        for phase in sorted(data.keys()):
            discovery.append({"item": phase, "params": _default_params(),
                              "metrics": ["power"]})
        return {"changed": False,
                "msg": "discovered %d power phases" % len(discovery),
                "data": {"discovery": discovery,
                         "host_labels": {"cmk/epower": "present"}}}

    item = params.get("item", "")
    data = _read_epower_data(ctx, params)
    if data == None:
        return {"changed": False, "msg": "no epower data source found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    power = data.get(item)
    if power == None:
        return {"changed": False,
                "msg": "no such power phase: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    warn, crit = _resolve_levels(params.get("levels_upper"))
    lower_warn, lower_crit = _resolve_levels(params.get("levels_lower"))
    state = "OK"
    if isinstance(power, (int, float)) and not (warn == None and crit == None):
        if not (warn == None) and power >= warn:
            state = "WARN"
        if not (crit == None) and power >= crit:
            state = "CRIT"
    if not (lower_warn == None) and isinstance(power, (int, float)):
        if power <= lower_warn:
            if state == "OK":
                state = "WARN"
        if not (lower_crit == None) and power <= lower_crit:
            state = "CRIT"
    label = _render_power(power)
    return {"changed": False,
            "msg": "Power phase %s: %s" % (item, label),
            "data": {"state": state, "metrics": {"power": power}, "details": label}}


def _read_epower_data(ctx, params):
    path = params.get("epower_path", "/run/epower.json")
    if not ctx.file_exists(path):
        probe = ctx.run(["epowerctl", "list", "--format", "json"], mutates=False)
        if probe.rc != 0:
            return None
        if not probe.stdout:
            return None
        return _parse_probe_output(probe.stdout)
    raw = ctx.file_read(path)
    if not raw or raw.strip() == "":
        return None
    return json.decode(raw)


def _parse_probe_output(stdout):
    data = json.decode(stdout)
    result = {}
    for entry in data:
        phase = entry.get("phase")
        power = entry.get("power")
        if phase != None and power != None:
            result[phase] = int(power)
    return result


def _default_params():
    return {"levels_lower": [20, 1], "levels_upper": None}


def _resolve_levels(levels):
    if levels == None:
        return (None, None)
    if type(levels) == "list":
        w = levels[0] if len(levels) > 0 else None
        c = levels[1] if len(levels) > 1 else None
        return (w, c)
    return (None, None)


def _render_power(p):
    if type(p) == "int":
        return str(int(p)) + " W"
    return str(p) + " W"