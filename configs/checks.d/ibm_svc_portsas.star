def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["svcinfo", "lssasport"], mutates=False)
        if res.rc != 0:
            if res.rc == 127:
                return {"changed": False, "msg": "svcinfo not installed",
                        "data": {"discovery": [], "host_labels": {}}}
            return {"changed": False, "msg": "svcinfo lssasport failed: " + res.stderr,
                    "data": {"discovery": [], "host_labels": {}}}
        dflt_header = [
            "id", "port_id", "port_speed", "node_id", "node_name",
            "WWPN", "status", "switch_WWPN", "attachment", "type",
            "adapter_location", "adapter_port_id",
        ]
        rows = _parse_ibm_svc_with_header(res.stdout, dflt_header)
        discovery = []
        seen = {}
        for id_, data in rows.items():
            status = data.get("status", "")
            if status == "offline_unconfigured":
                continue
            if "node_id" in data and "adapter_location" in data and "adapter_port_id" in data:
                item_name = "Node %s Slot %s Port %s" % (
                    data["node_id"], data["adapter_location"], data["adapter_port_id"])
            else:
                item_name = "Port %s" % id_
            if item_name in seen:
                continue
            seen[item_name] = True
            discovery.append({"item": item_name,
                              "params": {"current_state": status},
                              "metrics": []})
        return {"changed": False,
                "msg": "discovered %d SAS ports" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {"cmk/os_family": "ibm_svc"}}}
    item = params.get("item", "")
    res = ctx.run(["svcinfo", "lssasport"], mutates=False)
    if res.rc != 0:
        if res.rc == 127:
            return {"changed": False, "msg": "svcinfo not installed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "svcinfo lssasport failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dflt_header = [
        "id", "port_id", "port_speed", "node_id", "node_name",
        "WWPN", "status", "switch_WWPN", "attachment", "type",
        "adapter_location", "adapter_port_id",
    ]
    rows = _parse_ibm_svc_with_header(res.stdout, dflt_header)
    data = _resolve_item(rows, item)
    if data == None:
        return {"changed": False, "msg": "no such SAS port: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sasport_status = data.get("status", "")
    current_state = params.get("current_state", "offline")
    state = "OK" if sasport_status == current_state else "CRIT"
    port_speed = data.get("port_speed", "")
    ptype = data.get("type", "")
    msg = "Status: %s, Speed: %s, Type: %s" % (sasport_status, port_speed, ptype)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}


def _parse_ibm_svc_with_header(stdout, dflt_header):
    parsed = {}
    header = dflt_header
    for line in stdout.splitlines():
        if " command not found" in line:
            continue
        fields = line.split(":")
        if len(fields) == 0 or fields[0] == "":
            continue
        if fields[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = fields
            continue
        if len(fields) < 2:
            continue
        if len(header) == 0:
            header = dflt_header
        row = {}
        for i in range(1, len(fields)):
            col = i - 1
            if col < len(header):
                row[header[i]] = fields[i]
        if len(fields) > len(header) + 1 and len(header) >= 1:
            row[header[-1]] = fields[len(header):] and fields[len(header)]
        parsed.setdefault(fields[0], []).append(row)
    return parsed


def _resolve_item(parsed, item):
    for id_, rows in parsed.items():
        if len(rows) == 0:
            continue
        data = rows[0]
        if "node_id" in data and "adapter_location" in data and "adapter_port_id" in data:
            item_name = "Node %s Slot %s Port %s" % (
                data["node_id"], data["adapter_location"], data["adapter_port_id"])
        else:
            item_name = "Port %s" % id_
        if item_name == item:
            return data
    return None