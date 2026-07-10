def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lsrdev", "-c", "cl"], mutates=False)
        lines = res.stdout.splitlines() if res.rc == 0 else []
        nodes = []
        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue
            parts = stripped.split()
            if len(parts) >= 2 and parts[0].lower() == "cluster":
                node_name = parts[1].rstrip(":")
                if node_name:
                    nodes.append(node_name)
        discovery = []
        for node in nodes:
            discovery.append({
                "item": node,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d HACMP nodes" % len(nodes),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    # Get cluster device information to locate the node
    res = ctx.run(["lsrdev", "-c", "cl"], mutates=False)
    lines = res.stdout.splitlines() if res.rc == 0 else []
    node_data = {}
    current_node = None
    current_network = None

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split()
        if len(parts) >= 2 and parts[0].lower() == "cluster":
            current_node = parts[1].rstrip(":")
            if current_node == item:
                node_data[current_node] = {}
            else:
                current_node = None
            current_network = None
        elif current_node == item and len(parts) >= 4 and "interfaces" in stripped.lower():
            current_network = parts[3].rstrip(",")
            if current_node not in node_data:
                node_data[current_node] = {}
            node_data[current_node][current_network] = []
        elif current_node == item and current_network and "communication" in stripped.lower() and len(parts) >= 9:
            # Format: "Communication protocol : ... , name : ethX , attribute : ..., IP Address : x.x.x.x"
            # Extract: name (index 3), attribute (index 5), IP (index 8)
            name = parts[3].rstrip(",")
            attribute = parts[5].rstrip(",")
            ip_address = parts[8].rstrip(",")
            node_data[current_node][current_network].append({
                "name": name,
                "attribute": attribute,
                "ip_address": ip_address
            })

    data = node_data.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "node '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Build summary for all networks and interfaces
    infotext = ""
    for network_name in data:
        infotext = "Network: %s" % network_name
        for interface in data[network_name]:
            infotext += ", interface: %s, attribute: %s, IP: %s" % (
                interface["name"],
                interface["attribute"],
                interface["ip_address"]
            )

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }
