def main(ctx, params):
    # Discovery mode: emit single service
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: fetch SNMP data
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.12124.1.1.1", ".1.3.6.1.4.1.12124.1.1.2",
        ".1.3.6.1.4.1.12124.1.1.5", ".1.3.6.1.4.1.12124.1.1.6",
        ".1.3.6.1.4.1.12124.2.1.1", ".1.3.6.1.4.1.12124.2.1.2"
    ], mutates=False)

    # Parse SNMP output: extract oid=value lines
    lines = res.stdout.splitlines()
    data = {}
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_val = parts[0].strip()
        value = parts[1].strip()
        # Extract last number from OID suffix (e.g., .1 -> 1)
        idx_str = oid_val.rsplit(".", 1)[-1]
        if idx_str.isdigit():
            data[int(idx_str)] = value

    # Map expected indices based on original SNMP trees:
    # Tree 1 (.1.3.6.1.4.1.12124.1.1): 1=clusterName, 2=clusterHealth, 5=configuredNodes, 6=onlineNodes
    # Tree 2 (.1.3.6.1.4.1.12124.2.1): 1=nodeName, 2=nodeHealth -> .1.3.6.1.4.1.12124.2.1.2 = index 21
    configured_nodes = data.get(5)
    online_nodes = data.get(6)

    # Validate presence of required data for the Nodes check
    if configured_nodes == None or online_nodes == None:
        return {
            "changed": False,
            "msg": "unable to retrieve required SNMP data for Nodes check",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Guard: ensure strings are numeric before converting
    configured_int = int(configured_nodes) if configured_nodes.isdigit() else -1
    online_int = int(online_nodes) if online_nodes.isdigit() else -1

    if configured_int < 0 or online_int < 0:
        return {
            "changed": False,
            "msg": "SNMP data contains non-integer values for node counts",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Determine state: OK if all configured nodes are online, CRIT otherwise
    state = "OK" if configured_int == online_int else "CRIT"
    summary = "Configured Nodes: %s / Online Nodes: %s" % (configured_nodes, online_nodes)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
