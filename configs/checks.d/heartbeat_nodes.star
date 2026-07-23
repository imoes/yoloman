def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/heartbeat/nodes"], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) > 0 and f[0] != "":
                out.append({"item": f[0], "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d nodes" % len(out),
                "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/heartbeat/nodes"], mutates=False)
    
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) == 0:
            continue
        node_name = f[0]
        if node_name != item:
            continue
        
        status = "OK"
        node_status = f[1] if len(f) > 1 else ""
        
        link_output = ""
        for i in range(2, len(f), 2):
            if i + 1 < len(f):
                link = f[i]
                state = f[i + 1]
                state_txt = ""
                if state != "up":
                    status = "CRIT"
                    state_txt = " (!!)"
                link_output += link + ": " + state + state_txt + ", "
        link_output = link_output.rstrip(", ")
        
        if node_status in ["active", "up", "ping"] and status == "OK":
            status = "OK"
        elif node_status == "dead":
            status = "CRIT"
        
        if node_status not in ["active", "up", "ping", "dead"]:
            return {"changed": False, "msg": "Node " + node_name + " has an unhandled state: " + node_status,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        return {"changed": False, "msg": "Node " + node_name + " is in state \"" + node_status + "\". Links: " + link_output,
                "data": {"state": status, "metrics": {}, "details": ""}}
    
    return {"changed": False, "msg": "Node is not present anymore",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}