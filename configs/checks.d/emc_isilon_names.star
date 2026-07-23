def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch cluster and node name from emc_isilon section
    # SNMPTree base=".1.3.6.1.4.1.12124.1.1" with oids ["1", "2", "5", "6"]
    # SNMPTree base=".1.3.6.1.4.1.12124.2.1" with oids ["1", "2"]
    cluster_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.12124.1.1.1", ".1.3.6.1.4.1.12124.1.1.2",
        ".1.3.6.1.4.1.12124.1.1.5", ".1.3.6.1.4.1.12124.1.1.6"
    ], mutates=False)
    
    node_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.12124.2.1.1", ".1.3.6.1.4.1.12124.2.1.2"
    ], mutates=False)
    
    if cluster_res.rc != 0 or node_res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    cluster_name = ""
    node_name = ""
    
    # Parse cluster name: OID .1.3.6.1.4.1.12124.1.1.1
    for line in cluster_res.stdout.splitlines():
        line = line.strip()
        if line.startswith(".1.3.6.1.4.1.12124.1.1.1"):
            parts = line.split(" = ")
            if len(parts) >= 2:
                value = parts[1].strip()
                if value.startswith("STRING:"):
                    cluster_name = value[7:].strip(' "')
                else:
                    cluster_name = value.strip(' "')
                break
    
    # Parse node name: OID .1.3.6.1.4.1.12124.2.1.1
    for line in node_res.stdout.splitlines():
        line = line.strip()
        if line.startswith(".1.3.6.1.4.1.12124.2.1.1"):
            parts = line.split(" = ")
            if len(parts) >= 2:
                value = parts[1].strip()
                if value.startswith("STRING:"):
                    node_name = value[7:].strip(' "')
                else:
                    node_name = value.strip(' "')
                break
    
    return {
        "changed": False,
        "msg": "Cluster Name is %s, Node Name is %s" % (cluster_name, node_name),
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }
