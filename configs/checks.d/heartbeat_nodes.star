def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["crm", "resource", "-LR"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "heartbeat not found", "data": {"discovery": []}}
        section = []
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) >= 1 and f[0] != "":
                section.append(f)
        out = []
        for line in section:
            if len(line) >= 1 and line[0] != "":
                out.append({"item": line[0], "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["crm", "resource", "-LR"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "heartbeat not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = []
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) >= 1 and f[0] != "":
            section.append(f)
    for line in section:
        if len(line) >= 1 and line[0] == item:
            status = "OK"
            node_status = line[1] if len(line) >= 2 else ""
            link_output = ""
            links = line[2::2]
            states = line[3::2]
            for link, state in zip(links, states):
                state_txt = ""
                if state != "up":
                    status = "CRIT"
                    state_txt = " (!)"
                link_output += link + ": " + state + state_txt + ", "
            link_output = link_output.rstrip(", ")
            if node_status in ["active", "up", "ping"] and status == "OK":
                status = "OK"
            elif node_status == "dead":
                status = "CRIT"
            if node_status not in ["active", "up", "ping", "dead"]:
                return {"changed": False, "msg": "Node " + line[0] + " has an unhandled state: " + node_status, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            return {"changed": False, "msg": 'Node ' + line[0] + ' is in state "' + node_status + '". Links: ' + link_output, "data": {"state": status, "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Node is not present anymore", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}