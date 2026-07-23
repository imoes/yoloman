def _parse_mdstat(content):
    parsed = {}
    instance = None

    for raw_line in content.splitlines():
        line = raw_line.split()
        if len(line) == 0:
            continue

        if len(line) >= 5 and line[0].startswith("md") and line[1] == ":":
            if line[3].startswith("(") and line[3].endswith(")"):
                raid_state = line[2] + line[3]
                raid_name = line[4]
                disk_list = line[5:]
            else:
                raid_state = line[2]
                raid_name = line[3]
                disk_list = line[4:]

            spare_disks = len([x for x in disk_list if x.endswith("(S)")])
            failed_disks = len([x for x in disk_list if x.endswith("(F)")])
            active_disks = len(disk_list) - spare_disks - failed_disks

            instance = {
                "raid_name": raid_name,
                "raid_state": raid_state,
                "spare_disks": spare_disks,
                "failed_disks": failed_disks,
                "active_disks": active_disks,
            }
            parsed[line[0]] = instance

        elif instance != None:
            if line[0].startswith("resync="):
                parts = line[0].split("=")
                if len(parts) >= 2:
                    instance["resync_state"] = parts[1]
                continue

            if len(line) >= 2 and line[0].startswith("[") and line[0].endswith("]"):
                for idx, e in enumerate(line[1:]):
                    if e.startswith("finish="):
                        instance["finish"] = e.split("=")[1]
                    elif e.startswith("speed="):
                        instance["speed"] = e.split("=")[1]
                    elif e == "recovery" or e == "resync" or e == "check":
                        target = idx + 3
                        if target < len(line):
                            instance[e + "_values"] = line[target]
                continue

            if line[-1].startswith("[") and line[-1].endswith("]"):
                instance["working_disks"] = line[-1][1:-1]

            if len(line) >= 2 and line[-2].startswith("[") and line[-2].endswith("]"):
                nd_parts = line[-2][1:-1].split("/")
                if len(nd_parts) == 2:
                    if nd_parts[0].isdigit():
                        instance["num_disks"] = int(nd_parts[0])
                    if nd_parts[1].isdigit():
                        instance["expected_disks"] = int(nd_parts[1])

    return parsed


def _worst(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(a, 0) >= order.get(b, 0):
        return a
    return b


def main(ctx, params):
    if not ctx.file_exists("/proc/mdstat"):
        if params.get("_discover"):
            return {"changed": False, "msg": "no /proc/mdstat", "data": {"discovery": []}}
        return {"changed": False, "msg": "no /proc/mdstat",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read("/proc/mdstat")
    parsed = _parse_mdstat(content)

    if params.get("_discover"):
        out = []
        for device in sorted(parsed.keys()):
            attrs = parsed[device]
            if attrs["raid_name"] != "raid0":
                out.append({
                    "item": device,
                    "params": {},
                    "metrics": ["spare_disks", "failed_disks", "active_disks",
                                "num_disks", "expected_disks"],
                })
        return {"changed": False, "msg": "discovered %d md devices" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    data = parsed.get(item)
    if data == None:
        return {"changed": False, "msg": "MD device not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    overall = "OK"
    parts = []

    raid_state = data["raid_state"]
    if raid_state == "active" or raid_state == "active(auto-read-only)":
        parts.append("Status: " + raid_state)
    else:
        parts.append("Status: %s (should be 'active')" % raid_state)
        overall = _worst(overall, "CRIT")

    spare_disks = data["spare_disks"]
    failed_disks = data["failed_disks"]
    active_disks = data["active_disks"]
    parts.append("Spare: %d, Failed: %d, Active: %d" % (spare_disks, failed_disks, active_disks))

    num_disks = data.get("num_disks")
    expected_disks = data.get("expected_disks")
    working_disks = data.get("working_disks")
    if num_disks != None and expected_disks != None and working_disks != None:
        disk_info = "Status: %d/%d, %s" % (num_disks, expected_disks, working_disks)
        parts.append(disk_info)
        if num_disks != expected_disks or active_disks != working_disks.count("U"):
            overall = _worst(overall, "CRIT")

    header = "[Resync/Recovery]"
    op_parts = []

    if "resync_state" in data:
        header = "[Resync]"
        op_parts.append("Status: " + data["resync_state"])

    if "resync_values" in data:
        header = "[Resync]"
        op_parts.append(data["resync_values"])

    if "recovery_values" in data:
        header = "[Recovery]"
        op_parts.append(data["recovery_values"])

    if "finish" in data:
        op_parts.append("Finish: " + data["finish"])

    if "speed" in data:
        op_parts.append("Speed: " + data["speed"])

    if "check_values" in data:
        header = "[Check]"
        op_parts.append("Status: " + data["check_values"])
        parts.append("%s %s" % (header, ", ".join(op_parts)))
    elif len(op_parts) > 0:
        parts.append("%s %s" % (header, ", ".join(op_parts)))
        overall = _worst(overall, "WARN")

    metrics = {
        "spare_disks": spare_disks,
        "failed_disks": failed_disks,
        "active_disks": active_disks,
    }
    if num_disks != None:
        metrics["num_disks"] = num_disks
    if expected_disks != None:
        metrics["expected_disks"] = expected_disks

    return {
        "changed": False,
        "msg": "; ".join(parts),
        "data": {
            "state": overall,
            "metrics": metrics,
            "details": "",
        },
    }