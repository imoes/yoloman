DFLT_HEADER = [
    "id", "name", "UPS_serial_number", "WWNN", "status",
    "IO_group_id", "IO_group_name", "config_node", "UPS_unique_id",
    "hardware", "iscsi_name", "iscsi_alias", "panel_name",
    "enclosure_id", "canister_id", "enclosure_serial_number",
    "site_id", "site_name",
]

HEADER_IDS = ["id", "node_id", "mdisk_id", "enclosure_id"]

def _parse_lsnode(stdout):
    header = DFLT_HEADER
    groups = {}
    for raw in stdout.splitlines():
        line = raw.strip()
        if not line:
            continue
        if "command not found" in line:
            continue
        parts = line.split(":")
        if len(parts) < 2:
            continue
        if parts[0] in HEADER_IDS:
            header = parts
            continue
        row = {}
        for key, val in zip(header[1:], parts[1:]):
            row[key] = val
        io_group = row.get("IO_group_name", "")
        if not io_group:
            continue
        if io_group not in groups:
            groups[io_group] = []
        groups[io_group].append(row)
    return groups

def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "superuser")

    res = ctx.run(
        ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
         "-l", user, host, "lsnode", "-delim", ":"],
        mutates=False,
    )

    if res.rc != 0:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "lsnode failed: " + res.stderr,
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "lsnode failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    groups = _parse_lsnode(res.stdout)

    if params.get("_discover"):
        items = []
        for grp_name in sorted(groups.keys()):
            items.append({
                "item": grp_name,
                "params": {},
                "metrics": ["online_nodes", "total_nodes"],
            })
        return {
            "changed": False,
            "msg": "discovered %d IO groups" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    nodes = groups.get(item)

    if nodes == None or len(nodes) == 0:
        return {
            "changed": False,
            "msg": "IO Group %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    messages = []
    online_nodes = 0
    total_nodes = len(nodes)

    for row in nodes:
        node_name = row.get("name", "?")
        node_status = row.get("status", "unknown")
        messages.append("Node %s is %s" % (node_name, node_status))
        if node_status == "online":
            online_nodes += 1

    if total_nodes == online_nodes:
        state = "OK"
    elif online_nodes == 0:
        state = "CRIT"
    else:
        state = "WARN"

    summary = ", ".join(sorted(messages))

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"online_nodes": online_nodes, "total_nodes": total_nodes},
            "details": "",
        },
    }