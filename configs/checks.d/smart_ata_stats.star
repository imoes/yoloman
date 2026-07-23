def main(ctx, params):
    # Get list of SMART disks via 'smartctl --scan'
    res = ctx.run(["smartctl", "--scan"], mutates=False)
    devices = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "/dev/":
            device = parts[1]
            # Get device type (ATA/SCSI)
            type_res = ctx.run(["smartctl", "-i", device], mutates=False)
            if "ATA" in type_res.stdout:
                devices[device] = {"type": "ATA", "name": device.lstrip("/dev/")}

    if params.get("_discover"):
        out = []
        for item, disk in devices.items():
            if disk["type"] != "ATA":
                continue
            # Gather SMART attributes for this device to build discovered params
            attrs_res = ctx.run(["smartctl", "-A", item], mutates=False)
            lines = attrs_res.stdout.splitlines()
            params_map = {
                "id_5": None, "id_10": None, "id_184": None, "id_187": None,
                "id_188": None, "id_196": None, "id_197": None, "id_199": None
            }
            for line in lines:
                parts = line.split()
                if len(parts) < 10:
                    continue
                if parts[0].isdigit():
                    attr_id = int(parts[0])
                    if parts[9].isdigit():
                        raw = int(parts[9])
                        if "id_%d" % attr_id in params_map:
                            params_map["id_%d" % attr_id] = raw
            out.append({"item": item, "params": params_map, "metrics": [
                "harddrive_reallocated_sectors", "harddrive_spin_retries",
                "harddrive_end_to_end_errors", "harddrive_uncorrectable_errors",
                "harddrive_reallocated_events", "harddrive_pending_sectors",
                "harddrive_udma_crc_errors", "harddrive_crc_errors",
                "harddrive_cmd_timeouts", "harddrive_power_cycles", "uptime"
            ]})
        return {"changed": False, "msg": "discovered %d devices" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item not in devices:
        return {"changed": False, "msg": "device not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather SMART attributes
    attrs_res = ctx.run(["smartctl", "-A", item], mutates=False)
    lines = attrs_res.stdout.splitlines()
    attrs = {}
    for line in lines:
        parts = line.split()
        if len(parts) < 10:
            continue
        if parts[0].isdigit():
            attr_id = int(parts[0])
            raw = 0
            if parts[9].isdigit():
                raw = int(parts[9])
            name = parts[1] if len(parts) > 1 else ""
            attrs[attr_id] = {"raw": raw, "name": name}

    # Gather power on time (in hours)
    info_res = ctx.run(["smartctl", "-i", item], mutates=False)
    power_on_hours = None
    for line in info_res.stdout.splitlines():
        if "Power_On_Hours" in line or "Power On Hours" in line or "Power-on" in line:
            colon_parts = line.split(":")
            if len(colon_parts) >= 2:
                after_colon = colon_parts[1].strip()
                space_parts = after_colon.split()
                if len(space_parts) > 0 and space_parts[0].isdigit():
                    power_on_hours = int(space_parts[0])
                break
    # Try alternate parsing
    if power_on_hours == None:
        for line in info_res.stdout.splitlines():
            if "hours" in line.lower() and ("power" in line.lower() or "on" in line.lower()):
                for part in line.split():
                    if part.isdigit():
                        power_on_hours = int(part)
                        break
                if power_on_hours != None:
                    break

    state = "OK"
    summary_parts = []
    metrics = {}

    # ID 5: Reallocated_Sector_Ct
    if 5 in attrs:
        value = attrs[5]["raw"]
        param = params.get("levels_5", ("discovered_value", None))
        discovered_value = params.get("id_5")
        state, summary = _check_level(param, value, discovered_value, "Reallocated sectors", "harddrive_reallocated_sectors", state, metrics)
        summary_parts.append(summary)

    # Power on time in hours -> seconds for uptime
    if power_on_hours != None:
        value = power_on_hours * 3600
        state = "CRIT" if value > 1000000 else state  # rough heuristic, no levels for uptime in this check
        summary_parts.append("Powered on: %d hours" % power_on_hours)
        metrics["uptime"] = value

    # ID 10: Spin_Retry_Count
    if 10 in attrs:
        value = attrs[10]["raw"]
        param = params.get("levels_10", ("discovered_value", None))
        discovered_value = params.get("id_10")
        state, summary = _check_level(param, value, discovered_value, "Spin retries", "harddrive_spin_retries", state, metrics)
        summary_parts.append(summary)

    # ID 12: Power_Cycle_Count
    if 12 in attrs:
        value = attrs[12]["raw"]
        summary_parts.append("Power cycles: %d" % value)
        metrics["harddrive_power_cycles"] = value

    # ID 184: End-to-End_Error
    if 184 in attrs:
        value = attrs[184]["raw"]
        param = params.get("levels_184", ("discovered_value", None))
        discovered_value = params.get("id_184")
        state, summary = _check_level(param, value, discovered_value, "End-to-End Errors", "harddrive_end_to_end_errors", state, metrics)
        summary_parts.append(summary)

    # ID 187: Uncorrectable_Error_Count
    if 187 in attrs:
        value = attrs[187]["raw"]
        param = params.get("levels_187", ("discovered_value", None))
        discovered_value = params.get("id_187")
        state, summary = _check_level(param, value, discovered_value, "Uncorrectable errors", "harddrive_uncorrectable_errors", state, metrics)
        summary_parts.append(summary)

    # ID 188: Command_Timeout_Count
    if 188 in attrs:
        value = attrs[188]["raw"]
        summary_parts.append("Command Timeout Counter: %d" % value)
        metrics["harddrive_cmd_timeouts"] = value

    # ID 196: Reallocated_Event_Count
    if 196 in attrs:
        value = attrs[196]["raw"]
        param = params.get("levels_196", ("discovered_value", None))
        discovered_value = params.get("id_196")
        state, summary = _check_level(param, value, discovered_value, "Reallocated events", "harddrive_reallocated_events", state, metrics)
        summary_parts.append(summary)

    # ID 197: Pending_Sector_Count
    if 197 in attrs:
        value = attrs[197]["raw"]
        param = params.get("levels_197", ("discovered_value", None))
        discovered_value = params.get("id_197")
        state, summary = _check_level(param, value, discovered_value, "Pending sectors", "harddrive_pending_sectors", state, metrics)
        summary_parts.append(summary)

    # ID 199: CRC_Error_Count (UDMA_CRC_Error_Count)
    if 199 in attrs:
        value = attrs[199]["raw"]
        name = attrs[199]["name"]
        param = params.get("levels_199", ("discovered_value", None))
        discovered_value = params.get("id_199")
        label = "UDMA CRC errors" if "UDMA" in name else "CRC errors"
        metric = "harddrive_udma_crc_errors" if "UDMA" in name else "harddrive_crc_errors"
        state, summary = _check_level(param, value, discovered_value, label, metric, state, metrics)
        summary_parts.append(summary)

    msg = "%s: %s" % (item, ", ".join(summary_parts)) if summary_parts else "%s: no SMART data" % item
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _check_level(param, value, discovered_value, label, metric_name, state, metrics):
    if param == None or type(param) != "dict" or param.get(1) == None:
        # discovered_value mode
        if discovered_value != None and value > discovered_value:
            state = "CRIT"
            summary = "%s: %d (during discovery: %d) (!)" % (label, value, discovered_value)
        else:
            summary = "%s: %d" % (label, value)
    else:
        # fixed levels mode: param is ("levels_upper", (warn, crit))
        levels_upper = param[1]
        warn, crit = levels_upper
        if value >= crit:
            state = "CRIT"
            summary = "%s: %d (warn/crit at %d/%d) (!)" % (label, value, warn, crit)
        elif value >= warn:
            state = "WARN"
            summary = "%s: %d (warn/crit at %d/%d) !" % (label, value, warn, crit)
        else:
            summary = "%s: %d" % (label, value)
    metrics[metric_name] = value
    return state, summary