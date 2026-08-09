def _parse_md(text):
    parsed = {}
    instance = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) >= 5 and parts[0].startswith("md") and parts[1] == ":":
            if parts[3].startswith("(") and parts[3].endswith(")"):
                raid_state = parts[2] + parts[3]
                raid_name = parts[4]
                disk_list = parts[5:]
            else:
                raid_state = parts[2]
                raid_name = parts[3]
                disk_list = parts[4:]
            spare_disks = len([x for x in disk_list if x.endswith("(S)")])
            failed_disks = len([x for x in disk_list if x.endswith("(F)")])
            instance = parsed.setdefault(
                parts[0],
                {
                    "raid_name": raid_name,
                    "raid_state": raid_state,
                    "spare_disks": spare_disks,
                    "failed_disks": failed_disks,
                    "active_disks": len(disk_list) - spare_disks - failed_disks,
                },
            )
        elif instance:
            if parts[0].startswith("resync="):
                k, v = parts[0].split("=")
                instance[k + "_state"] = v
                continue
            if len(parts) >= 2 and parts[0].startswith("[") and parts[0].endswith("]"):
                for idx, e in enumerate(parts[1:]):
                    if e.startswith("finish=") or e.startswith("speed="):
                        k, v = e.split("=")
                        instance[k] = v
                    elif e in ["recovery", "resync", "check"]:
                        instance[e + "_values"] = parts[idx + 3]
                continue
            if parts[-1].startswith("[") and parts[-1].endswith("]"):
                instance["working_disks"] = parts[-1][1:-1]
            if len(parts) >= 2 and parts[-2].startswith("[") and parts[-2].endswith("]"):
                keys = ["num_disks", "expected_disks"]
                vals = parts[-2][1:-1].split("/")
                for key, value in zip(keys, vals):
                    if value.isdigit():
                        instance[key] = int(value)
    return parsed


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/mdstat"], mutates=False)
        if res.rc == 127 or not res.stdout.strip():
            return {"changed": False, "msg": "no mdadm software raid found", "data": {"discovery": []}}
        parsed = _parse_md(res.stdout)
        discovery = []
        for device, attrs in sorted(parsed.items()):
            if attrs["raid_name"] != "raid0":
                discovery.append({"item": device, "params": {}, "metrics": ["spare_disks", "failed_disks", "active_disks"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/mdstat"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no mdadm software raid found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = _parse_md(res.stdout)
    data = parsed.get(item)
    if data == None:
        return {"changed": False, "msg": "no such md device: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {"spare_disks": data["spare_disks"], "failed_disks": data["failed_disks"], "active_disks": data["active_disks"]}
    raid_state = data["raid_state"]
    infotext = "Status: %s" % raid_state
    if raid_state in ["active", "active(auto-read-only)"]:
        state = "OK"
    else:
        infotext += " (should be 'active')"
        state = "CRIT"

    details = infotext + "\nSpare: %d, Failed: %d, Active: %d" % (data["spare_disks"], data["failed_disks"], data["active_disks"])

    num_disks = data.get("num_disks")
    expected_disks = data.get("expected_disks")
    working_disks = data.get("working_disks")
    if num_disks != None and expected_disks != None and working_disks != None:
        infotext = "Status: %d/%d, %s" % (num_disks, expected_disks, working_disks)
        if num_disks == expected_disks and data["active_disks"] == working_disks.count("U"):
            details += "\n" + infotext
        else:
            state = "CRIT"
            details += "\n" + infotext

    header = "[Resync/Recovery]"
    infotexts = []
    if "resync_state" in data:
        header = "[Resync]"
        infotexts.append("Status: %s" % data["resync_state"])
    if "resync_values" in data:
        header = "[Resync]"
        infotexts.append(data["resync_values"])
    if "recovery_values" in data:
        header = "[Recovery]"
        infotexts.append(data["recovery_values"])
    if "finish" in data:
        infotexts.append("Finish: %s" % data["finish"])
    if "speed" in data:
        infotexts.append("Speed: %s" % data["speed"])
    if "check_values" in data:
        header = "[Check]"
        infotexts.append("Status: %s" % data["check_values"])

    if infotexts:
        line = header + " " + ", ".join(infotexts)
        details += "\n" + line
        if "check_values" not in data:
            if state == "OK":
                state = "WARN"
            elif state == "CRIT":
                pass
        else:
            if state == "OK":
                state = "OK"
    elif state == "OK" and not infotexts:
        state = "OK"

    if state == "CRIT":
        pass
    elif state == "WARN":
        pass

    msg = "Status: %s, Spare: %d, Failed: %d, Active: %d" % (raid_state, data["spare_disks"], data["failed_disks"], data["active_disks"])
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}