def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["sshpass", "-p", params.get("password", ""), "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", 
                       params.get("username", "3paradm") + "@" + params.get("host", "localhost"), 
                       "cli", "-F", "systemshow -json"], mutates=False)
        if res.rc != 0:
            res = ctx.run(["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", 
                           params.get("username", "3paradm") + "@" + params.get("host", "localhost"), 
                           "cli", "-F", "systemshow -json"], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "failed to connect to 3PAR system", "data": {"discovery": []}}
        
        if not res.stdout:
            return {"changed": False, "msg": "no data from 3PAR system", "data": {"discovery": []}}
        
        data = json.decode(res.stdout) if res.stdout else {}
        
        system_name = data.get("name")
        if system_name:
            return {"changed": False, "msg": "discovered 1 3PAR system", 
                    "data": {"discovery": [{"item": system_name, "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "no 3PAR system found", "data": {"discovery": []}}
    
    # Check mode
    item = params.get("item", "")
    
    res = ctx.run(["sshpass", "-p", params.get("password", ""), "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", 
                   params.get("username", "3paradm") + "@" + params.get("host", "localhost"), 
                   "cli", "-F", "systemshow -json"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", 
                       params.get("username", "3paradm") + "@" + params.get("host", "localhost"), 
                       "cli", "-F", "systemshow -json"], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "failed to connect to 3PAR system", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if not res.stdout:
        return {"changed": False, "msg": "no data from 3PAR system", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    
    if data.get("name") != item:
        return {"changed": False, "msg": "item %s not found" % item, 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    model = data.get("model", "N/A")
    version = data.get("systemVersion", "N/A")
    serial = data.get("serialNumber", "N/A")
    cluster_nodes = data.get("clusterNodes", [])
    online_nodes = data.get("onlineNodes", [])
    
    summary = "Model: %s, Version: %s, Serial number: %s, Online nodes: %d/%d" % (
        model, version, serial, len(online_nodes), len(cluster_nodes))
    
    state = "OK"
    details = ""
    
    if len(online_nodes) < len(cluster_nodes):
        state = "CRIT"
        missing_nodes = list(set(cluster_nodes) ^ set(online_nodes))
        missing_nodes.sort()
        details_list = []
        for n in range(len(missing_nodes)):
            details_list.append("Node %d not available" % missing_nodes[n])
        details = ", ".join(details_list)
        summary += ", " + details
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": details}}