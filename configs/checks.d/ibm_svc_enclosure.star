def main(ctx, params):
    # discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/driver/ibm_svc_enclosure"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read enclosure data",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        parsed = _parse_svc_enclosure(lines)
        if not parsed:
            return {"changed": False, "msg": "no enclosure data found",
                    "data": {"discovery": []}}
        discovery_list = []
        for item in parsed:
            discovery_list.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d enclosures" % len(discovery_list),
                "data": {"discovery": discovery_list}}

    # check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/driver/ibm_svc_enclosure"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read enclosure data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    section = _parse_svc_enclosure(lines)
    data = section.get(item)
    if data == None:
        return {"changed": False, "msg": "enclosure %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    enclosure_status = data.get("status", "")
    if enclosure_status == "online":
        state = "OK"
    else:
        state = "CRIT"

    summary = "Status: %s" % enclosure_status
    metrics = {}

    for key, label in [
        ("canisters", "canisters"),
        ("PSUs", "PSUs"),
        ("fan_modules", "fan modules"),
        ("sems", "secondary expander modules"),
    ]:
        online_str = data.get("online_" + key)
        total_str = data.get("total_" + key)
        online = _try_int(online_str)
        total = _try_int(total_str)
        if online == None:
            continue
        metrics["online_" + key] = online
        if total != None:
            summary += ", Online %s: %d of %d" % (label, online, total)
        else:
            summary += ", Online %s: %d" % (label, online)

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _try_int(value):
    if value == None:
        return None
    s = str(value).strip()
    if not s:
        return None
    negative = s.startswith("-")
    digits_part = s[1:] if negative else s
    if digits_part.isdigit():
        return int(s)
    return None


def _parse_svc_enclosure(info):
    dflt_header = _get_default_header(info)
    if dflt_header == None:
        return {}

    parsed = {}
    header = dflt_header
    for line in info:
        stripped = line.strip()
        if not stripped:
            continue
        cells = stripped.split(":")
        if len(cells) < 2:
            continue
        if cells[0] == "id" or cells[0] == "enclosure_id":
            header = cells
            continue
        id_ = cells[0]
        row = dict(zip(header[1:], cells[1:]))
        parsed.setdefault(id_, row)

    return parsed


def _get_default_header(info):
    # Guard instead of try/except
    if len(info) == 0:
        return None

    first_line = info[0]
    cells = first_line.strip().split(":")
    n = len(cells)
    if n == 9:
        return [
            "id",
            "status",
            "type",
            "product_MTM",
            "serial_number",
            "total_canisters",
            "online_canisters",
            "online_PSUs",
            "drive_slots",
        ]
    if n == 13:
        return [
            "id",
            "status",
            "type",
            "managed",
            "IO_group_id",
            "IO_group_name",
            "product_MTM",
            "serial_number",
            "total_canisters",
            "online_canisters",
            "total_PSUs",
            "online_PSUs",
            "drive_slots",
        ]
    if n == 15:
        return [
            "id",
            "status",
            "type",
            "managed",
            "IO_group_id",
            "IO_group_name",
            "product_MTM",
            "serial_number",
            "total_canisters",
            "online_canisters",
            "total_PSUs",
            "online_PSUs",
            "drive_slots",
            "total_fan_modules",
            "online_fan_modules",
        ]
    if n == 17:
        return [
            "id",
            "status",
            "type",
            "managed",
            "IO_group_id",
            "IO_group_name",
            "product_MTM",
            "serial_number",
            "total_canisters",
            "online_canisters",
            "total_PSUs",
            "online_PSUs",
            "drive_slots",
            "total_fan_modules",
            "online_fan_modules",
            "total_sems",
            "online_sems",
        ]
    return None