def main(ctx, params):
    if params.get("_discover"):
        # Probe for the IBM SVC CLI first.
        ver = ctx.run(["svcinfo", "lsnode", "-delim", ":"], mutates=False)
        if ver.rc == 127:
            # Not installed — check does not apply to this host.
            return {"changed": False, "msg": "svcinfo not available", "data": {"discovery": []}}
        if ver.rc != 0:
            return {"changed": False, "msg": "", "data": {"discovery": []}}

        res = ctx.run(["svcinfo", "lsportfc", "-delim", ":"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "", "data": {"discovery": []}}

        dflt_header = [
            "id", "fc_io_port_id", "port_id", "type", "port_speed",
            "node_id", "node_name", "WWPN", "nportid", "status",
            "attachment", "cluster_use", "adapter_location", "adapter_port_id",
        ]

        parsed = {}
        header = dflt_header
        for line in res.stdout.splitlines():
            f = line.split(":")
            if not f:
                continue
            if " command not found" in line:
                continue
            if f[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
                header = f
            else:
                row = dict(zip(header[1:], f[1:]))
                parsed.setdefault(f[0], []).append(row)

        discovery = []
        for id_, rows in parsed.items():
            if not rows:
                continue
            data = rows[0]
            if "node_id" in data and "adapter_location" in data and "adapter_port_id" in data:
                item_name = "Node %s Slot %s Port %s" % (data["node_id"], data["adapter_location"], data["adapter_port_id"])
            else:
                item_name = "Port %s" % id_
            if data.get("status") != "active":
                continue
            discovery.append({"item": item_name, "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    # Check mode.
    item = params.get("item", "")

    # Confirm the CLI is present.
    ver = ctx.run(["svcinfo", "lsportfc", "-delim", ":"], mutates=False)
    if ver.rc == 127:
        return {"changed": False, "msg": "svcinfo not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if ver.rc != 0:
        return {"changed": False, "msg": "", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["svcinfo", "lsportfc", "-delim", ":"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    dflt_header = [
        "id", "fc_io_port_id", "port_id", "type", "port_speed",
        "node_id", "node_name", "WWPN", "nportid", "status",
        "attachment", "cluster_use", "adapter_location", "adapter_port_id",
    ]

    parsed = {}
    header = dflt_header
    for line in res.stdout.splitlines():
        f = line.split(":")
        if not f:
            continue
        if " command not found" in line:
            continue
        if f[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = f
        else:
            row = dict(zip(header[1:], f[1:]))
            parsed.setdefault(f[0], []).append(row)

    data = None
    for id_, rows in parsed.items():
        if not rows:
            continue
        r = rows[0]
        if "node_id" in r and "adapter_location" in r and "adapter_port_id" in r:
            candidate = "Node %s Slot %s Port %s" % (r["node_id"], r["adapter_location"], r["adapter_port_id"])
        else:
            candidate = "Port %s" % id_
        if candidate == item:
            data = r
            break

    if data == None:
        return {"changed": False, "msg": "no such port: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    port_status = data["status"]
    infotext = "Status: %s, Speed: %s, WWPN: %s" % (port_status, data.get("port_speed", ""), data.get("WWPN", ""))
    state = "OK" if port_status == "active" else "CRIT"

    return {"changed": False, "msg": infotext, "data": {"state": state, "metrics": {}, "details": ""}}