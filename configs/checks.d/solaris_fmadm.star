def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["fmadm", "faulty"], mutates=False)
        if res.rc != 0 and res.rc != 1:
            return {"changed": False, "msg": "not installed", "data": {"discovery": []}}
        if res.rc == 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        # rc == 1 means no faults
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        # If faults present (rc==0 with output), single service
    item = params.get("item", "")
    res = ctx.run(["fmadm", "faulty"], mutates=False)
    if res.rc != 0 and res.rc != 1:
        return {"changed": False, "msg": "fmadm not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    parsed = _parse(lines)
    if not parsed:
        return {"changed": False, "msg": "No faults detected",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    event = parsed["event"]
    map_state = {
        "minor": ("WARN", "minor"),
        "major": ("CRIT", "major"),
        "critical": ("CRIT", "critical"),
    }
    state, state_readable = map_state.get(event["severity"], ("UNKNOWN", "unknown"))
    summary = "Severity: " + state_readable + " (" + event["time"] + ")"
    problems = parsed["problems"]
    if problems:
        summary = summary + " Problems: " + ", ".join(problems)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}


def _parse(lines):
    if len(lines) < 4:
        return {}
    event = []
    # string_table[3] is colon-joined; lines[3] corresponds
    header_line = lines[3]
    parts = []
    for entry in header_line.split(":"):
        entry = entry.strip()
        if entry == "":
            continue
        parts.append(entry)
    event = parts
    problems = []
    for line in lines[4:]:
        stripped = line.strip()
        if stripped == "":
            continue
        tokens = []
        for t in stripped.split(" "):
            t = t.strip()
            if t != "":
                tokens.append(t)
        if len(tokens) == 0:
            continue
        if tokens[0] in ["Problem", "Fault"]:
            # "Problem class X" or "Fault class X"
            if len(tokens) >= 3 and tokens[1] in ["class", "Class"]:
                # Problem class : value  or  Fault class : value
                problems.append(stripped)
    # Re-parse event fields
    if len(event) < 4:
        return {}
    return {
        "event": {
            "time": " ".join(event[:-3]),
            "id": event[-3],
            "msg": event[-2],
            "severity": event[-1].lower(),
        },
        "problems": problems,
    }