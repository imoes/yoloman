def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["showsys", "-d", "-json"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "3PAR not available", "data": {"discovery": [], "host_labels": {}}}
        if not res.stdout:
            return {"changed": False, "msg": "no 3PAR data", "data": {"discovery": [], "host_labels": {}}}
        data = json.decode(res.stdout)
        name = data.get("name")
        if not name:
            return {"changed": False, "msg": "no 3PAR system name", "data": {"discovery": [], "host_labels": {}}}
        metrics = ["online_nodes", "cluster_nodes"]
        discovery = [{"item": name, "params": {}, "metrics": metrics,
                      "service_labels": {"3par/model": data.get("model", "N/A"),
                                         "3par/system_version": data.get("systemVersion", "N/A"),
                                         "3par/serial_number": data.get("serialNumber", "N/A")}}]
        labels = {"cmk/os_family": ctx.facts().get("os_family", "linux")}
        return {"changed": False, "msg": "discovered 3PAR system", "data": {"discovery": discovery, "host_labels": labels}}

    item = params.get("item", "")
    res = ctx.run(["showsys", "-d", "-json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "3PAR not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    name = data.get("name", "")
    if item and name != item:
        return {"changed": False, "msg": "3PAR system not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    model = data.get("model", "N/A")
    system_version = data.get("system_version", data.get("systemVersion", "N/A"))
    serial_number = data.get("serial_number", data.get("serialNumber", "N/A"))
    cluster_nodes = data.get("clusterNodes", data.get("cluster_nodes", []))
    online_nodes = data.get("onlineNodes", data.get("online_nodes", []))

    summary = "Model: %s, Version: %s, Serial number: %s, Online nodes: %d/%d" % (
        model, system_version, serial_number, len(online_nodes), len(cluster_nodes))

    details_lines = [summary]
    state = "OK"
    for node in set(cluster_nodes) ^ set(online_nodes):
        details_lines.append("(Node %d not available)" % node)
        if state == "OK":
            state = "CRIT"

    metrics = {"online_nodes": len(online_nodes), "cluster_nodes": len(cluster_nodes)}
    return {"changed": False,
            "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": "\n".join(details_lines)}}