def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lssrc", "-a"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "lssrc not available (AIX)", "data": {"discovery": [], "host_labels": {}}}
        if res.rc != 0:
            return {"changed": False, "msg": "lssrc failed", "data": {"discovery": []}}

        # Build a synthetic table mimicking the Checkmk agent <<<aix_hacmp_services>>> section.
        # We look for RSCT (cthags, ctrmc), PowerHA (clstrmgrES, clevmgrdES), and CAA (clcomd, clconfd) subsystems.
        subsystems = {}
        lines = res.stdout.splitlines()
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line == "":
                i += 1
                continue

            # Detect subsystem type group headers by known subsystem names
            # RSCT section
            if line.startswith("cthags") or line.startswith("ctrmc"):
                if "RSCT" not in subsystems:
                    subsystems["RSCT"] = []
                parts = line.split()
                if len(parts) >= 3:
                    name = parts[0]
                    status = parts[-1]
                    subsystems["RSCT"].append((name, status))

            # PowerHA SystemMirror section
            elif line.startswith("clstrmgrES") or line.startswith("clevmgrdES"):
                if "PowerHA SystemMirror" not in subsystems:
                    subsystems["PowerHA SystemMirror"] = []
                parts = line.split()
                if len(parts) >= 3:
                    name = parts[0]
                    status = parts[-1]
                    subsystems["PowerHA SystemMirror"].append((name, status))

            # CAA section
            elif line.startswith("clcomd") or line.startswith("clconfd"):
                if "CAA" not in subsystems:
                    subsystems["CAA"] = []
                parts = line.split()
                if len(parts) >= 2:
                    name = parts[0]
                    status = parts[-1]
                    subsystems["CAA"].append((name, status))

            i += 1

        discovery = []
        for group, subs in subsystems.items():
            if len(subs) > 0:
                discovery.append({
                    "item": group,
                    "params": {},
                    "metrics": [],
                })

        return {"changed": False, "msg": "discovered %d HACMP service groups" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")

    # Gather on-host data the same way the Checkmk agent plugin would.
    res = ctx.run(["lssrc", "-a"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "lssrc not available (AIX)", "data": {"state": "UNKNOWN", "metrics": {}, "details": "lssrc command not found"}}
    if res.rc != 0:
        return {"changed": False, "msg": "lssrc failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": "lssrc returned non-zero exit code"}}

    # Reproduce the parsed section: {group_name: [(subsystem_name, status), ...]}
    parsed = {}
    lines = res.stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line == "":
            i += 1
            continue

        group = None
        if line.startswith("cthags") or line.startswith("ctrmc"):
            group = "RSCT"
        elif line.startswith("clstrmgrES") or line.startswith("clevmgrdES"):
            group = "PowerHA SystemMirror"
        elif line.startswith("clcomd") or line.startswith("clconfd"):
            group = "CAA"

        if group != None:
            parts = line.split()
            if len(parts) >= 3:
                name = parts[0]
                status = parts[-1]
                parsed.setdefault(group, []).append((name, status))

        i += 1

    data = parsed.get(item)
    if data == None or len(data) == 0:
        return {"changed": False, "msg": "HACMP service group %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": "no data found for group %s" % item}}

    states = []
    msgs = []
    for subsystem_name, status in data:
        state = "OK" if status == "active" else "CRIT"
        states.append(state)
        msgs.append("Subsystem: %s, Status: %s" % (subsystem_name, status))

    overall_state = "OK"
    if "CRIT" in states:
        overall_state = "CRIT"

    return {"changed": False, "msg": "; ".join(msgs), "data": {"state": overall_state, "metrics": {}, "details": ""}}