def main(ctx, params):
    if params.get("_discover"):
        return discover(ctx, params)
    return check(ctx, params)

def discover(ctx, params):
    section = get_section(ctx)
    if section == None:
        return {"changed": False, "msg": "no AppDynamics memory data found",
                "data": {"discovery": []}}
    items = []
    for line in section:
        if len(line) >= 2:
            item = line[0] + " " + line[1]
            items.append({"item": item, "params": {"warn": None, "crit": None},
                          "metrics": ["mem_heap", "mem_heap_committed", "mem_nonheap", "mem_nonheap_committed"]})
    n = len(items)
    return {"changed": False, "msg": "discovered %d items" % n,
            "data": {"discovery": items}}

def check(ctx, params):
    section = get_section(ctx)
    if section == None:
        return {"changed": False, "msg": "no AppDynamics memory data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    item = params.get("item", "")
    for line in section:
        if len(line) >= 2 and item == line[0] + " " + line[1]:
            return grade_line(line, params)
    return {"changed": False, "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

def get_section(ctx):
    res = ctx.run(["cat", "/tmp/.appdynamics_memory"], mutates=False)
    if res.rc != 0:
        res2 = ctx.run(["ls", "-1", "/tmp"], mutates=False)
        return None
    out = res.stdout
    section = []
    for raw in out.split("\n"):
        line = raw.split("|")
        if len(line) >= 2:
            section.append(line)
    if len(section) == 0:
        return None
    return section

def grade_line(line, params):
    mb = 1024 * 1024
    item = line[0] + " " + line[1]
    if item.endswith("Non-Heap"):
        mem_type = "nonheap"
    elif item.endswith("Heap"):
        mem_type = "heap"
    else:
        mem_type = ""

    values = {}
    for metric in line[2:]:
        parts = metric.split(":")
        if len(parts) >= 2:
            values[parts[0]] = parts[1]

    used = to_mb(values.get("Current Usage (MB)", "0")) * mb
    committed = to_mb(values.get("Committed (MB)", "0")) * mb
    max_avail_str = values.get("Max Available (MB)", "")
    max_available = to_mb(max_avail_str) * mb if max_avail_str != "" else -1

    used_percent = (100.0 * used / max_available) if max_available > 0 else 0.0

    if max_available > 0:
        levels = params.get(mem_type, (None, None))
        warn = levels[0] if type(levels) == "list" and len(levels) >= 1 else None
        crit = levels[1] if type(levels) == "list" and len(levels) >= 2 else None
    else:
        warn = None
        crit = None

    warn_bytes = None
    crit_bytes = None
    warn_label = ""
    crit_label = ""

    if type(crit) == "float":
        crit_label = "%f%%" % crit
        crit_bytes = int((max_available / 100.0) * crit)
    elif type(crit) == "int":
        crit_label = "%d MB free" % crit
        crit_bytes = max_available - (crit * mb)

    if type(warn) == "float":
        warn_label = "%f%%" % warn
        warn_bytes = int((max_available / 100.0) * warn)
    elif type(warn) == "int":
        warn_label = "%d MB free" % warn
        warn_bytes = max_available - (warn * mb)

    state = "OK"
    if crit_bytes != None and used >= crit_bytes:
        state = "CRIT"
    elif warn_bytes != None and used >= warn_bytes:
        state = "WARN"

    levels_label = ""
    if state != "OK" and (warn_label != "" or crit_label != ""):
        levels_label = " (levels at %s/%s)" % (warn_label, crit_label)

    metrics = {}
    metrics["mem_" + mem_type] = used
    metrics["mem_" + mem_type + "_committed"] = committed

    if max_available > 0:
        summary = "Used: %s of %s (%f%%)%s" % (render_bytes(used), render_bytes(max_available), used_percent, levels_label)
        metrics["mem_" + mem_type + "_used_percent"] = used_percent
    else:
        summary = "Used: %s%s" % (render_bytes(used), levels_label)

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics,
                     "details": "Committed: %s" % render_bytes(committed)}}

def to_mb(s):
    if s == "" or s == None:
        return 0
    parts = s.split(".")
    if len(parts) > 1:
        return 0
    return int(s) if s.isdigit() else 0

def render_bytes(b):
    mb = 1024 * 1024
    gb = mb * 1024
    tb = gb * 1024
    if b >= tb:
        return "%f TB" % (b / tb)
    if b >= gb:
        return "%f GB" % (b / gb)
    if b >= mb:
        return "%f MB" % (b / mb)
    if b >= 1024:
        return "%d KB" % (b / 1024)
    return "%d B" % b