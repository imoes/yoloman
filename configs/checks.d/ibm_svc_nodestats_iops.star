def main(ctx, params):
    # Discovery mode: enumerate IOPS-capable items
    if params.get("_discover"):
        # Probe the data source: ibm_svc_nodestats agent section
        # The Checkmk agent plugin for IBM SVC runs 'svc_ls_nodestats'
        res = ctx.run([
            "svc_ls_nodestats",
            "-noheader",
            "-fieldseparator", ":"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "svc_ls_nodestats command failed or not found",
                "data": {"discovery": []}
            }
        lines = res.stdout.strip().split("\n")
        parsed = {}
        for line in lines:
            if not line:
                continue
            fields = line.split(":")
            if len(fields) < 6:
                continue
            node_id, node_name, stat_name, stat_current = fields[0], fields[1], fields[2], fields[3]
            # Only consider r_io and w_io
            if stat_name != "r_io" and stat_name != "w_io":
                continue
            # Determine base type (vdisk, mdisk, drive)
            base = stat_name.replace("r_", "").replace("w_", "").replace("_io", "")
            if base == "vdisk":
                item_name = "VDisks " + node_name
            elif base == "mdisk":
                item_name = "MDisks " + node_name
            elif base == "drive":
                item_name = "Drives " + node_name
            else:
                continue
            # Initialize dict for this item if needed
            if item_name not in parsed:
                parsed[item_name] = {}
            # Convert stat_current to float only if numeric
            val = float(stat_current) if stat_current.replace(".", "").replace("-", "").replace("+", "").replace("e", "").isdigit() else 0.0
            parsed[item_name][stat_name] = val
        items = []
        for item_name, data in parsed.items():
            if "r_io" in data and "w_io" in data:
                items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": ["read", "write"]
                })
        return {
            "changed": False,
            "msg": "discovered %d IOPS items" % len(items),
            "data": {"discovery": items}
        }
    # Check mode: examine one item
    item = params.get("item", "")
    res = ctx.run([
        "svc_ls_nodestats",
        "-noheader",
        "-fieldseparator", ":"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "svc_ls_nodestats command failed or not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    lines = res.stdout.strip().split("\n")
    # Parse to get r_io and w_io for the item
    item_iops = {"r_io": 0.0, "w_io": 0.0}
    found_r = False
    found_w = False
    for line in lines:
        if not line:
            continue
        fields = line.split(":")
        if len(fields) < 6:
            continue
        node_id, node_name, stat_name, stat_current = fields[0], fields[1], fields[2], fields[3]
        # Determine base type and item name
        if stat_name != "r_io" and stat_name != "w_io":
            continue
        base = stat_name.replace("r_", "").replace("w_", "").replace("_io", "")
        if base == "vdisk":
            check_item = "VDisks " + node_name
        elif base == "mdisk":
            check_item = "MDisks " + node_name
        elif base == "drive":
            check_item = "Drives " + node_name
        else:
            continue
        if check_item == item:
            # Convert stat_current to float only if numeric
            val = float(stat_current) if stat_current.replace(".", "").replace("-", "").replace("+", "").replace("e", "").isdigit() else 0.0
            item_iops[stat_name] = val
            if stat_name == "r_io":
                found_r = True
            elif stat_name == "w_io":
                found_w = True
    # Check if we found data for this item
    if not found_r or not found_w:
        return {
            "changed": False,
            "msg": "no IOPS data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    read_iops = item_iops["r_io"]
    write_iops = item_iops["w_io"]
    return {
        "changed": False,
        "msg": "%d IOPS read, %d IOPS write" % (read_iops, write_iops),
        "data": {
            "state": "OK",
            "metrics": {"read": read_iops, "write": write_iops},
            "details": ""
        }
    }