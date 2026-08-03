# SMART %s Stats — read-only Starlark check module
# Translates Checkmk check plugin smart_stats into an on-host probe using
# `smartctl` from the smartmontools package.

ATTRIBUTE_DISPLAY = {
    "Reallocated_Sectors": "Reallocated sectors",
    "Power_On_Hours": "Powered on",
    "Spin_Retries": "Spin retries",
    "Power_Cycles": "Power cycles",
    "End_To_End_Errors": "End-to-end errors",
    "Uncorrectable_Errors": "Uncorrectable errors",
    "Command_Timeout_Counter": "Command timeout counter",
    "Reallocated_Events": "Reallocated events",
    "Pending_Sectors": "Pending sectors",
    "UDMA_CRC_Errors": "UDMA CRC errors",
    "CRC_Errors": "CRC errors",
}

CAPTURE_ON_DISCOVERY = [
    "Reallocated_Sectors",
    "Spin_Retries",
    "End_To_End_Errors",
    "Uncorrectable_Errors",
    "Command_Timeout_Counter",
    "Reallocated_Events",
    "Pending_Sectors",
    "UDMA_CRC_Errors",
    "CRC_Errors",
    "Critical_Warning",
    "Media_and_Data_Integrity_Errors",
]

MAX_COMMAND_TIMEOUTS_PER_HOUR = 100

ATA_ID_TO_ATTRIBUTE = {
    5: "Reallocated_Sectors",
    9: "Power_On_Hours",
    10: "Spin_Retries",
    12: "Power_Cycles",
    184: "End_To_End_Errors",
    187: "Uncorrectable_Errors",
    188: "Command_Timeout_Counter",
    194: "Temperature",
    196: "Reallocated_Events",
    197: "Pending_Sectors",
    199: "CRC_Errors",
}


def _is_int(s):
    if s == "" or s == None:
        return False
    start = 0
    if s[0:1] == "-":
        start = 1
    if start >= len(s):
        return False
    for ch in s[start:]:
        if ch < "0" or ch > "9":
            return False
    return True


def _to_int(s):
    return int(s) if _is_int(s) else 0


def _parse_smartctl_ata(output):
    attrs = {}
    lines = output.split("\n")
    seen_header = False
    for line in lines:
        parts = line.split()
        if len(parts) < 10:
            continue
        if not seen_header:
            if parts[0] == "ID#" and parts[1] == "ATTRIBUTE_NAME":
                seen_header = True
            continue
        attr_id = _to_int(parts[0])
        attr_name = parts[1]
        raw_value = parts[9]
        if len(parts) > 10:
            raw_value = " ".join(parts[9:])

        if attr_name == "Unknown_Attribute":
            canonical = ATA_ID_TO_ATTRIBUTE.get(attr_id)
            if canonical == None:
                continue
            attrs[canonical] = _to_int(raw_value)
            continue

        canonical = ATA_ID_TO_ATTRIBUTE.get(attr_id)
        if canonical != None:
            attrs[canonical] = _to_int(raw_value)
        else:
            attrs[attr_name] = _to_int(raw_value)

        if canonical == "Reallocated_Events":
            attrs["_normalized_value_Reallocated_Events"] = _to_int(parts[3])
            attrs["_normalized_threshold_Reallocated_Events"] = _to_int(parts[5])

    return attrs


def _parse_smartctl_nvme(output):
    attrs = {}
    lines = output.split("\n")
    for line in lines:
        parts = line.split(":")
        if len(parts) < 2:
            continue
        field = parts[0].strip()
        value_str = parts[1].strip()
        value_clean = value_str.replace("%", "").replace(",", "").replace(" ", "")
        key = field.replace(" ", "_")

        if field == "Temperature":
            tokens = value_str.split()
            attrs[key] = _to_int(tokens[0]) if len(tokens) > 0 else 0
        elif field == "Critical Warning":
            if value_str.startswith("0x"):
                hex_part = value_str[2:]
                attrs[key] = _to_int(hex_part)
            else:
                attrs[key] = _to_int(value_str)
        elif field == "Data Units Read":
            tokens = value_str.split()
            attrs[key] = _to_int(tokens[0]) * 512000 if len(tokens) > 0 else 0
        elif field == "Data Units Written":
            tokens = value_str.split()
            attrs[key] = _to_int(tokens[0]) * 512000 if len(tokens) > 0 else 0
        elif field == "Available_Spare":
            attrs[key] = _to_int(value_clean)
        elif field == "Available_Spare_Threshold":
            attrs[key] = _to_int(value_clean)
        elif field == "Percentage_Used":
            attrs[key] = _to_int(value_clean)
        elif field == "Power_On_Hours":
            attrs[key] = _to_int(value_str)
        elif field == "Media_and_Data_Integrity_Errors":
            attrs[key] = _to_int(value_str)
        else:
            attrs[key] = _to_int(value_str)

    return attrs


def _get_smart_disks(ctx):
    res = ctx.run(["smartctl", "--scan"], mutates=False)
    if res.rc != 0:
        return []
    disks = []
    for line in res.stdout.split("\n"):
        if line.strip() == "":
            continue
        parts = line.split()
        if len(parts) > 0:
            dev = parts[0]
            if dev.startswith("/dev/"):
                disks.append(dev)
    seen = {}
    unique = []
    for d in disks:
        if d not in seen:
            seen[d] = True
            unique.append(d)
    return unique


def _gather_smart_attrs(ctx, device):
    res = ctx.run(["smartctl", "-A", device], mutates=False)
    if res.rc != 0:
        return None

    output = res.stdout

    is_nvme = False
    for line in output.split("\n"):
        if "NVMe" in line and "Device" in line:
            is_nvme = True
            break

    if device.find("nvme") != -1:
        is_nvme = True

    if is_nvme:
        return _parse_smartctl_nvme(output)
    return _parse_smartctl_ata(output)


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["smartctl", "--version"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "smartctl not found, no SMART services discovered",
                "data": {"discovery": []},
            }

        disks = _get_smart_disks(ctx)
        discovery = []
        for dev in disks:
            attrs = _gather_smart_attrs(ctx, dev)
            if attrs == None or len(attrs) == 0:
                continue
            if len(attrs) == 1 and "Temperature" in attrs:
                continue

            captured = {}
            for attr_name in CAPTURE_ON_DISCOVERY:
                if attr_name in attrs:
                    captured[attr_name] = attrs[attr_name]

            entry = {
                "item": dev,
                "params": captured,
                "metrics": list(captured.keys()),
            }
            if len(captured) > 0:
                entry["service_labels"] = {
                    "cmk/disk_type": "nvme" if dev.find("nvme") != -1 else "ata",
                }
            discovery.append(entry)

        return {
            "changed": False,
            "msg": "discovered %d SMART devices" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no SMART device specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(["smartctl", "--version"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "smartctl not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    attrs = _gather_smart_attrs(ctx, item)
    if attrs == None:
        return {
            "changed": False,
            "msg": "no SMART data for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    details_parts = []
    state_rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    rank_max = 0

    for attr_name in CAPTURE_ON_DISCOVERY:
        if attr_name not in attrs:
            continue

        value = attrs[attr_name]
        ref_value = params.get(attr_name)

        if attr_name == "Temperature":
            continue

        display_name = ATTRIBUTE_DISPLAY.get(attr_name, attr_name)
        hint = ""
        state = "OK"

        if attr_name == "Command_Timeout_Counter":
            if ref_value != None and value > ref_value:
                if (value - ref_value) >= MAX_COMMAND_TIMEOUTS_PER_HOUR:
                    state = "CRIT"
                    hint = "counter increased more than %d counts / h (!!). during discovery: %d" % (
                        MAX_COMMAND_TIMEOUTS_PER_HOUR, ref_value)

        elif attr_name == "Reallocated_Events":
            norm_value = attrs.get("_normalized_value_Reallocated_Events")
            norm_threshold = attrs.get("_normalized_threshold_Reallocated_Events")
            if norm_value == None or norm_threshold == None:
                if ref_value != None and value > ref_value:
                    state = "CRIT"
                    hint = "during discovery: %d (!!)" % ref_value
            else:
                if value > ref_value or norm_value <= norm_threshold:
                    state = "CRIT"
                    hint = "during discovery: %d (!!)" % ref_value
                    if norm_value <= norm_threshold:
                        hint += " (normalized value below threshold)"

        elif attr_name == "Available_Spare":
            threshold = attrs.get("Available_Spare_Threshold")
            if threshold != None and value < threshold:
                state = "CRIT"
                hint = "during discovery: %d (!!) (threshold: %d)" % (threshold, threshold)
            elif ref_value != None and value < ref_value:
                state = "CRIT"
                hint = "during discovery: %d (!!) (threshold: %d)" % (ref_value, threshold)

        else:
            if ref_value != None and value > ref_value:
                state = "CRIT"
                hint = "during discovery: %d (!!)" % ref_value

        if state_rank.get(state, 0) > rank_max:
            rank_max = state_rank.get(state, 0)

        if hint:
            summary_line = "%s: %d (%s)" % (display_name, value, hint)
        else:
            summary_line = "%s: %d" % (display_name, value)

        details_parts.append(summary_line)
        metrics[attr_name] = value

    for attr_name in ["Power_On_Hours", "Power_Cycles", "Temperature"]:
        if attr_name in attrs and attr_name not in metrics:
            display_name = ATTRIBUTE_DISPLAY.get(attr_name, attr_name)
            value = attrs[attr_name]
            if attr_name == "Temperature":
                summary_line = "%s: %d C" % (display_name, value)
            else:
                summary_line = "%s: %d" % (display_name, value)
            details_parts.append(summary_line)
            metrics[attr_name] = value

    worst_state = "CRIT" if rank_max >= state_rank["CRIT"] else ("WARN" if rank_max >= state_rank["WARN"] else "OK")

    msg = "; ".join(details_parts) if len(details_parts) > 0 else "SMART OK"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": worst_state,
            "metrics": metrics,
            "details": "\n".join(details_parts),
        },
    }