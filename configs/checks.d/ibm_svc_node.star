def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["svcinfo", "lsnode", "-nohdr"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "svcinfo not installed", "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no io groups found", "data": {"discovery": []}}
        header = [
            "id", "name", "UPS_serial_number", "WWNN", "status",
            "IO_group_id", "IO_group_name", "config_node", "UPS_unique_id",
            "hardware", "iscsi_name", "iscsi_alias", "panel_name",
            "enclosure_id", "canister_id", "enclosure_serial_number",
            "site_id", "site_name"
        ]
        io_groups = []
        seen = set()
        for line in res.stdout.splitlines():
            if " command not found" in line:
                continue
            fields = line.split(":")
            if len(fields) < 2:
                continue
            if fields[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
                header = fields
                continue
            row = dict(zip(header[1:], fields[1:]))
            io_grp = row.get("IO_group_name", "")
            if io_grp and io_grp not in seen:
                seen.add(io_grp)
                io_groups.append(io_grp)
        discovery = []
        for grp in io_groups:
            discovery.append({"item": grp, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["svcinfo", "lsnode", "-nohdr"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "svcinfo not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no node data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    header = [
        "id", "name", "UPS_serial_number", "WWNN", "status",
        "IO_group_id", "IO_group_name", "config_node", "UPS_unique_id",
        "hardware", "iscsi_name", "iscsi_alias", "panel_name",
        "enclosure_id", "canister_id", "enclosure_serial_number",
        "site_id", "site_name"
    ]
    data = []
    for line in res.stdout.splitlines():
        if " command not found" in line:
            continue
        fields = line.split(":")
        if len(fields) < 2:
            continue
        if fields[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = fields
            continue
        row = dict(zip(header[1:], fields[1:]))
        if row.get("IO_group_name", "") == item:
            data.append(row)

    if not data:
        return {"changed": False, "msg": "IO Group %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    messages = []
    online_nodes = 0
    nodes_of_iogroup = 0
    for row in data:
        node_status = row.get("status", "")
        messages.append("Node %s is %s" % (row.get("name", ""), node_status))
        nodes_of_iogroup += 1
        if node_status == "online":
            online_nodes += 1

    if nodes_of_iogroup == 0:
        return {"changed": False, "msg": "IO Group %s not found in agent output" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if nodes_of_iogroup == online_nodes:
        state = "OK"
    elif online_nodes == 0:
        state = "CRIT"
    else:
        state = "WARN"

    return {"changed": False, "msg": ", ".join(sorted(messages)), "data": {"state": state, "metrics": {}, "details": ""}}