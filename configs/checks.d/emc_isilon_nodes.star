def main(ctx, params):
    if params.get("_discover"):
        return discover(ctx, params)
    return check(ctx, params)


def discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: check if this is an Isilon system via sysDescr
    sysdescr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", "-O0", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sysdescr.rc == 127:
        return {"changed": False, "msg": "snmpget not installed", "data": {"discovery": []}}
    if sysdescr.rc != 0:
        return {"changed": False, "msg": "cannot reach host via SNMP", "data": {"discovery": []}}

    # Check if the sysDescr contains "isilon" (DETECT_ISILON)
    descr_text = sysdescr.stdout
    if descr_text.find("isilon") == -1 and descr_text.lower().find("isilon") == -1:
        # Not an Isilon system
        return {"changed": False, "msg": "not an EMC Isilon system", "data": {"discovery": []}}

    # Fetch the two SNMP tables
    cluster_table = fetch_snmp_table(ctx, host, community, ".1.3.6.1.4.1.12124.1.1", ["1", "2", "5", "6"])
    node_table = fetch_snmp_table(ctx, host, community, ".1.3.6.1.4.1.12124.2.1", ["1", "2"])

    if len(cluster_table) == 0 or len(node_table) == 0:
        return {"changed": False, "msg": "no Isilon SNMP data found", "data": {"discovery": []}}

    # Discover all four check items (single-service checks, item="")
    discovery = [
        {"item": "", "params": {}, "metrics": []},
        {"item": "clusterhealth", "params": {}, "metrics": []},
        {"item": "nodehealth", "params": {}, "metrics": []},
        {"item": "nodes", "params": {}, "metrics": []},
        {"item": "names", "params": {}, "metrics": []},
    ]

    return {
        "changed": False,
        "msg": "discovered %d items" % len(discovery),
        "data": {"discovery": discovery},
    }


def check(ctx, params):
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # First verify this is an Isilon system
    sysdescr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", "-O0", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sysdescr.rc != 0:
        return {
            "changed": False,
            "msg": "cannot reach host via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    descr_text = sysdescr.stdout
    is_isilon = descr_text.find("isilon") != -1 or descr_text.lower().find("isilon") != -1

    if not is_isilon:
        return {
            "changed": False,
            "msg": "not an EMC Isilon system (no sysDescr match)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch the two SNMP tables
    cluster_table = fetch_snmp_table(ctx, host, community, ".1.3.6.1.4.1.12124.1.1", ["1", "2", "5", "6"])
    node_table = fetch_snmp_table(ctx, host, community, ".1.3.6.1.4.1.12124.2.1", ["1", "2"])

    if len(cluster_table) == 0:
        return {
            "changed": False,
            "msg": "no Isilon cluster SNMP data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if len(node_table) == 0:
        return {
            "changed": False,
            "msg": "no Isilon node SNMP data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # The item names from discovery are: "", "clusterhealth", "nodehealth", "nodes", "names"
    # Map "" to a default (we'll use "clusterhealth" as default for the blank item, 
    # but actually in the original each is a separate Service with item="")
    # Since each original check is a single-service check (yields Service() with no item),
    # the "" item maps to the first check. Let's handle each sub-check by its item name.
    
    if item == "" or item == "clusterhealth":
        return check_clusterhealth(cluster_table)
    elif item == "nodehealth":
        return check_nodehealth(node_table)
    elif item == "nodes":
        return check_nodes(cluster_table)
    elif item == "names":
        return check_names(cluster_table, node_table)

    return {
        "changed": False,
        "msg": "unknown item: %s" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }


def fetch_snmp_table(ctx, host, community, base_oid, col_oids):
    """Fetch an SNMP table using snmpwalk with -Oqn (numeric OID, no type).
    Returns a list of rows, where each row is a list of [col_oid, value] pairs
    sorted by column OID. Correlates rows by index."""
    results = {}

    for col in col_oids:
        full_oid = base_oid + "." + col
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, full_oid],
            mutates=False,
        )
        if res.rc != 0:
            continue
        for line in res.stdout.split("\n"):
            line = line.strip()
            if len(line) == 0:
                continue
            # Format: "<full_oid>.<index> <value>"
            space_idx = line.find(" ")
            if space_idx == -1:
                continue
            oid_part = line[:space_idx]
            value_part = line[space_idx + 1:]

            # The index is the suffix after the column base
            col_full = full_oid
            if oid_part.startswith(col_full + "."):
                index = oid_part[len(col_full) + 1:]
            else:
                continue

            if index not in results:
                results[index] = {}
            results[index][col] = value_part

    # Build rows sorted by index, each row as list of [col, value] in col order
    rows = []
    for index in sorted(results.keys()):
        row = {}
        row_data = []
        for col in col_oids:
            if col in results[index]:
                row_data.append([col, results[index][col]])
            else:
                row_data.append([col, ""])
        rows.append(row_data)

    return rows


def check_clusterhealth(cluster_table):
    statusmap = ["ok", "attn", "down", "invalid"]
    status = int(cluster_table[0][1][1])  # section[0][0][1] - second column of first row
    if status >= len(statusmap):
        return {
            "changed": False,
            "msg": "ClusterHealth reports unidentified status %d" % status,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    state = "OK" if status == 0 else "CRIT"
    return {
        "changed": False,
        "msg": "ClusterHealth reports status %s" % statusmap[status],
        "data": {"state": state, "metrics": {}, "details": ""},
    }


def check_nodehealth(node_table):
    statusmap = ["ok", "attn", "down", "invalid"]
    status = int(node_table[0][1][1])  # section[1][0][1] - second column of first row
    nodename = node_table[0][0][1]    # section[1][0][0] - first column of first row
    if status >= len(statusmap):
        return {
            "changed": False,
            "msg": "nodeHealth reports unidentified status %d" % status,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    state = "OK" if status == 0 else "CRIT"
    return {
        "changed": False,
        "msg": "nodeHealth for %s reports status %s" % (nodename, statusmap[status]),
        "data": {"state": state, "metrics": {}, "details": ""},
    }


def check_nodes(cluster_table):
    # section[0][0] = [cluster_name, cluster_health, configured_nodes, online_nodes]
    # In our fetch_snmp_table, each row is list of [col_oid_suffix, value]
    # cols are ["1", "2", "5", "6"] mapping to: cluster_name, cluster_health, configured_nodes, online_nodes
    row = cluster_table[0]
    cluster_name = row[0][1]
    cluster_health = row[1][1]
    configured_nodes = row[2][1]
    online_nodes = row[3][1]
    state = "OK" if configured_nodes == online_nodes else "CRIT"
    return {
        "changed": False,
        "msg": "Configured Nodes: %s / Online Nodes: %s" % (configured_nodes, online_nodes),
        "data": {"state": state, "metrics": {}, "details": ""},
    }


def check_names(cluster_table, node_table):
    cluster_name = cluster_table[0][0][1]  # first column of first row
    node_name = node_table[0][0][1]       # first column of first row
    return {
        "changed": False,
        "msg": "Cluster Name is %s, Node Name is %s" % (cluster_name, node_name),
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }