def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["pvecm", "--version"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "pvecm not found", "data": {"discovery": [], "host_labels": {}}}

        res = ctx.run(["pvecm", "status"], mutates=False)
        lines = res.stdout.splitlines()

        nodes = []
        header = None
        i = 0
        for idx in range(len(lines)):
            l = lines[idx]
            stripped = l.strip()
            if stripped == "Node Sts Inc Joined Name":
                header = "v2"
                continue
            if stripped == "Nodeid      Votes Name":
                header = "vgt2"
                continue
            if stripped == "Nodeid      Votes    Qdevice Name":
                header = "vgt2q"
                continue
            if header == None:
                continue
            f = l.split()
            if header == "v2":
                if len(f) >= 5 and f[0] != "Node":
                    nodes.append({"name": f[-1], "data": {"node_id": f[0], "status": f[1], "joined": f[3] + " " + f[4]}})
                else:
                    nodes.append({"name": f[-1], "data": {"node_id": f[0], "status": f[1]}})
            elif header == "vgt2":
                if len(f) >= 3 and f[0] != "Nodeid":
                    if f[0] == "0" and "QDevice" in f[-1]:
                        nodes.append({"name": f[-1], "data": {"node_id": f[0], "votes": f[1]}})
                    else:
                        nodes.append({"name": " ".join(f[2:]), "data": {"node_id": f[0], "votes": f[1]}})
            elif header == "vgt2q":
                if len(f) >= 4 and f[0] != "Nodeid":
                    nodes.append({"name": " ".join(f[3:]), "data": {"node_id": f[0], "votes": f[1], "qdevice": f[2]}})
                elif len(f) >= 3:
                    nodes.append({"name": f[-1], "data": {"node_id": f[0], "votes": f[1]}})

        discovery = []
        for n in nodes:
            discovery.append({"item": n["name"], "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d PVE nodes" % len(discovery), "data": {"discovery": discovery, "host_labels": {"cmk/pvecm": "true"}}}

    item = params.get("item", "")

    probe = ctx.run(["pvecm", "--version"], mutates=False)
    if probe.rc != 0:
        return {"changed": False, "msg": "pvecm not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["pvecm", "status"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no pvecm data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    header = None
    found = False
    data = None
    summaries = []

    for idx in range(len(lines)):
        l = lines[idx]
        stripped = l.strip()
        if stripped == "Node Sts Inc Joined Name":
            header = "v2"
            continue
        if stripped == "Nodeid      Votes Name":
            header = "vgt2"
            continue
        if stripped == "Nodeid      Votes    Qdevice Name":
            header = "vgt2q"
            continue
        if header == None:
            continue
        f = l.split()
        name_candidate = ""
        if header == "v2":
            name_candidate = f[-1] if len(f) >= 5 else (f[-1] if len(f) >= 2 else "")
            if name_candidate == item or (len(f) >= 5 and f[-1] == item):
                data = {"node_id": f[0], "status": f[1]}
                if len(f) >= 5:
                    data["joined"] = f[3] + " " + f[4]
                found = True
            summaries.append((name_candidate, f[0] if len(f) >= 1 else "", f[1] if len(f) >= 2 else ""))
        elif header == "vgt2":
            if len(f) >= 3 and f[0] != "Nodeid":
                name_candidate = " ".join(f[2:])
                data = {"node_id": f[0], "votes": f[1]}
                if name_candidate == item:
                    found = True
                summaries.append((name_candidate, f[0], f[1]))
        elif header == "vgt2q":
            if len(f) >= 4 and f[0] != "Nodeid":
                name_candidate = " ".join(f[3:])
                data = {"node_id": f[0], "votes": f[1], "qdevice": f[2]}
                if name_candidate == item:
                    found = True
                summaries.append((name_candidate, f[0], f[1]))

    if not found:
        return {"changed": False, "msg": "Node is missing: " + item, "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    map_states = {
        "m": ("OK", "member of the cluster"),
        "x": ("WARN", "not a member of the cluster"),
        "d": ("CRIT", "known to the cluster but disallowed access to it"),
    }

    parts = ["ID: " + str(data.get("node_id", ""))]

    if "status" in data:
        st = data["status"].lower()
        s = map_states.get(st)
        if s != None:
            parts.append("Status: " + s[1])
        else:
            parts.append("Status: " + str(data["status"]))

    if "joined" in data:
        parts.append("Joined: " + data["joined"])

    if "votes" in data:
        parts.append("Votes: " + str(data.get("votes", "")))

    if "qdevice" in data:
        parts.append("QDevice: " + str(data.get("qdevice", "")))

    final_state = "OK"
    if "status" in data:
        st = data["status"].lower()
        s = map_states.get(st)
        if s != None:
            final_state = s[0]

    return {"changed": False, "msg": ", ".join(parts), "data": {"state": final_state, "metrics": {}, "details": ""}}