def _parse_printer_line(line):
    parts = line.split()
    if len(parts) < 4:
        return None
    jobs_str = parts[-3]
    status_str = parts[-2]
    error_str = parts[-1]
    if not (jobs_str.isdigit() and status_str.isdigit() and error_str.isdigit()):
        return None
    name = " ".join(parts[:-3])
    return (name, int(jobs_str), int(status_str), int(error_str))

_STATUS_MAP = {
    1: "Other",
    2: "Unkown",
    3: "Idle",
    4: "Printing",
    5: "Warming Up",
    6: "Stopped Printing",
    7: "Offline",
}

_ERROR_MAP = {
    0: "Unkown",
    1: "Other",
    2: "No Error",
    3: "Low Paper",
    4: "No Paper",
    5: "Low Toner",
    6: "No Toner",
    7: "Door Open",
    8: "Jammed",
    9: "Offline",
    10: "Service Requested",
    11: "Output Bin Full",
}

def _get_printers(ctx):
    res = ctx.run(["lpstat", "-t"], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    text = res.stdout
    sections = text.split("\n\n")
    jobs_section = None
    for sec in sections:
        if sec.strip().startswith("printer"):
            jobs_section = sec
            break
    if jobs_section == None:
        return {}
    result = {}
    for line in jobs_section.split("\n"):
        line = line.strip()
        if not line.startswith("printer "):
            continue
        if "disabled" in line or "not connected" in line:
            continue
        name = line.split()[1]
        if name.endswith(":"):
            name = name[:-1]
        result[name] = (0, 3, 0)
    return result

def main(ctx, params):
    if params.get("_discover"):
        printers = _get_printers(ctx)
        if printers == None:
            return {"changed": False, "msg": "no printer system found",
                    "data": {"discovery": []}}
        discovery = []
        for name in sorted(printers.keys()):
            discovery.append({"item": name, "params": {}, "metrics": ["jobs"]})
        return {"changed": False, "msg": "discovered %d printers" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    printers = _get_printers(ctx)
    if printers == None:
        return {"changed": False, "msg": "lpstat not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    queue = printers.get(item)
    if queue == None:
        return {"changed": False, "msg": "no such printer: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    jobs, status, error = queue
    warn_states = params.get("warn_states", [8, 11])
    crit_states = params.get("crit_states", [9, 10])

    if error in crit_states:
        state = "CRIT"
    elif error in warn_states:
        state = "WARN"
    else:
        state = "OK"

    state_name = _STATUS_MAP.get(status, "Unknown")
    error_name = _ERROR_MAP.get(error, "Unknown")
    msg = "State: %s, Jobs: %d" % (state_name, jobs)
    if error != 0:
        msg = msg + ", Error: %s" % error_name

    details = "Printer: %s\nJobs: %d\nStatus: %s (code %d)\nError: %s (code %d)" % (
        item, jobs, state_name, status, error_name, error
    )

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"jobs": jobs}, "details": details}}