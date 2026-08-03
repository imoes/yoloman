def _grade_level(value, warn, crit):
    if value == None:
        return "OK"
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def _is_number(s):
    if s == None:
        return False
    s = s.strip()
    if s == "":
        return False
    for ch in s:
        if not (ch.isdigit() or ch == "." or ch == "-"):
            return False
    return True

def _to_float(s):
    if not _is_number(s):
        return None
    return float(s)

def _split_line(line):
    return [t for t in line.split(" ") if t != ""]

def _run_lparstat(ctx, args):
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        return None
    text = res.stdout
    if text == "" or text == None:
        return None
    return text.splitlines()

def _check_present(ctx):
    res = ctx.run(["lparstat", "-E"], mutates=False)
    if res.rc == 127:
        return False
    return res.rc == 0

def _parse_section(ctx):
    lines = _run_lparstat(ctx, ["lparstat", "-E"])
    if lines == None:
        return None
    system_config = {}
    idx = 0
    config_lines = []
    while idx < len(lines):
        stripped = lines[idx].strip()
        if stripped == "":
            idx = idx + 1
            continue
        parts = stripped.split(":", 1)
        if len(parts) == 2 and _is_number(parts[1].strip()):
            config_lines.append(stripped)
            idx = idx + 1
            continue
        break
    for cl in config_lines:
        parts = cl.split(":", 1)
        if len(parts) == 2:
            system_config[parts[0].strip()] = parts[1].strip()
    smt = system_config.get("smt", "")
    if smt.lower() == "on":
        system_config["smt"] = "2"
    header = None
    values = None
    for i in range(len(lines)):
        h = lines[i].strip()
        if h.startswith("CPU") or ("user" in h and "sys" in h):
            header = _split_line(h)
            j = i + 1
            while j < len(lines) and lines[j].strip() == "":
                j = j + 1
            if j < len(lines):
                values = _split_line(lines[j].strip())
            break
    cpu = {}
    util = {}
    if header != None and values != None and len(values) >= len(header):
        for k in range(len(header)):
            name = header[k].lstrip("%")
            uom = "%" if "%" in header[k] else ""
            idx_v = k + 1
            if idx_v < len(values):
                v = _to_float(values[idx_v])
                if v != None:
                    if name in ("user", "sys", "idle", "wait"):
                        cpu[name] = v
                    else:
                        util[name] = (v, uom)
    return {"system_config": system_config, "util": util, "cpu": cpu}

def main(ctx, params):
    if params.get("_discover") == True:
        if not _check_present(ctx):
            return {"changed": False, "msg": "no lparstat found",
                    "data": {"discovery": []}}
        section = _parse_section(ctx)
        if section == None:
            return {"changed": False, "msg": "no lparstat data",
                    "data": {"discovery": []}}
        cpu = section.get("cpu", {})
        has_required = ("user" in cpu and "sys" in cpu and "wait" in cpu and "idle" in cpu)
        if section.get("cpu", {}) and has_required:
            return {"changed": False, "msg": "discovered 1 CPU utilization service",
                    "data": {"discovery": [
                        {"item": "", "params": {},
                         "metrics": ["cpu_util", "cpu_entitlement_util", "cpu_entitlement"]}
                    ]}}
        return {"changed": False, "msg": "no CPU data in lparstat",
                "data": {"discovery": []}}

    if not _check_present(ctx):
        return {"changed": False, "msg": "no lparstat found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "lparstat not available"}}

    section = _parse_section(ctx)
    if section == None:
        return {"changed": False, "msg": "no lparstat data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "lparstat -E failed"}}

    sc = section.get("system_config", {})
    update_required = sc.get("update_required", None)
    if update_required == True:
        return {"changed": False, "msg": "Please upgrade your AIX agent.",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu = section.get("cpu", {})
    has_required = ("user" in cpu and "sys" in cpu and "wait" in cpu and "idle" in cpu)
    if not has_required:
        return {"changed": False, "msg": "incomplete CPU data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total = cpu["user"] + cpu["sys"] + cpu.get("idle", 0) + cpu["wait"]
    if total <= 0:
        return {"changed": False, "msg": "no CPU time",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    idle_pct = (cpu.get("idle", 0) / total) * 100.0
    util_pct = 100.0 - idle_pct

    warn = params.get("warn", None)
    crit = params.get("crit", None)
    levels = params.get("levels", None)
    if levels != None and type(levels) == "list":
        warn = levels[0]
        crit = levels[1]
    elif levels != None and type(levels) == "dict":
        warn = levels.get("warn", warn)
        crit = levels.get("crit", crit)

    state = "OK"
    if crit != None and util_pct >= crit:
        state = "CRIT"
    elif warn != None and util_pct >= warn:
        state = "WARN"

    metrics = {"cpu_util": util_pct}
    details = "user=%f%% sys=%f%% idle=%f%% wait=%f%% => util=%f%%" % (
        cpu["user"], cpu["sys"], cpu.get("idle", 0), cpu["wait"], util_pct)
    msg = "CPU utilization: %f%%" % util_pct

    util = section.get("util", {})
    physc_pair = util.get("physc", None)
    ent = _to_float(sc.get("ent", None))
    if physc_pair != None:
        physc = physc_pair[0]
        metrics["cpu_entitlement_util"] = physc
        p_state = _grade_level(physc, 90.0, 100.0)
        if p_state == "CRIT":
            state = "CRIT"
        elif p_state == "WARN" and state == "OK":
            state = "WARN"
        msg = msg + ", physc=%f CPUs" % physc
    if ent != None:
        metrics["cpu_entitlement"] = ent
        e_state = _grade_level(ent, 100.0, 150.0)
        if e_state == "CRIT":
            state = "CRIT"
        elif e_state == "WARN" and state == "OK":
            state = "WARN"
        msg = msg + ", ent=%f CPUs" % ent

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}