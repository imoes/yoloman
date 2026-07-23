def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "ntp_levels": [10, 200.0, 500.0],
                            "alert_delay": [1025, 3600]
                        },
                        "metrics": ["offset", "stratum", "time_since_last_sync"]
                    }
                ]
            }
        }

    res = ctx.run(["chronyc", "sources", "-n"], mutates=False)
    output = res.stdout.strip()

    if res.rc != 0 or "Cannot talk to daemon" in output:
        return {
            "changed": False,
            "msg": "Cannot talk to chronyd daemon",
            "data": {
                "state": "CRIT",
                "metrics": {},
                "details": ""
            }
        }

    lines = res.stdout.splitlines()
    if len(lines) < 3:
        return {
            "changed": False,
            "msg": "Unexpected chrony output format",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    source_line = None
    for line in lines[2:]:
        stripped = line.strip()
        if stripped and stripped[0] in ['*', '+', '-', '^', '#', '.']:
            source_line = stripped
            break

    if source_line == None:
        return {
            "changed": False,
            "msg": "No valid source line found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    fields = source_line.split()
    if len(fields) < 5:
        return {
            "changed": False,
            "msg": "Not enough fields in source line",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    stratum_str = fields[3] if len(fields) > 3 else ""
    stratum = int(stratum_str) if stratum_str.isdigit() else None

    offset_sec_str = fields[4] if len(fields) > 4 else ""
    offset_sec = float(offset_sec_str) if offset_sec_str.replace(".", "", 1).isdigit() else None

    tracking_res = ctx.run(["chronyc", "tracking", "-n"], mutates=False)
    if tracking_res.rc != 0:
        return {
            "changed": False,
            "msg": "Failed to get chrony tracking data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    tracking_lines = tracking_res.stdout.strip().splitlines()
    parsed = {}
    for line in tracking_lines:
        if ':' in line:
            key, value = line.split(':', 1)
            key = key.strip()
            value = value.strip()
            if key == "Reference ID":
                parsed["Reference ID"] = value
                if value:
                    parts = value.split()
                    if len(parts) >= 2:
                        ip = parts[1].strip("()")
                        if ip and len(ip) > 0 and ip != "()":
                            parsed["address"] = ip
            elif key == "System time":
                time_parts = value.split(" ")
                if len(time_parts) > 0:
                    val_str = time_parts[0]
                    if val_str.replace(".", "", 1).isdigit():
                        parsed[key] = float(val_str) * 1000
            elif key == "Stratum":
                if value.isdigit():
                    parsed[key] = int(value)

    address = parsed.get("address", "")

    ntp_levels = params.get("ntp_levels", [10, 200.0, 500.0])
    crit_stratum = ntp_levels[0]
    warn_offset = ntp_levels[1]
    crit_offset = ntp_levels[2]

    state = "OK"
    messages = []

    if "error" in parsed:
        state = "CRIT"
        messages.append(parsed["error"])
    else:
        if address == "":
            state = "WARN"
            messages.append("NTP servers unreachable")

    offset = abs(parsed.get("System time")) if parsed.get("System time") != None else None
    if offset != None:
        if offset >= crit_offset:
            state = "CRIT"
            messages.append("Offset %f ms >= %f ms critical threshold" % (offset, crit_offset))
        elif offset >= warn_offset:
            state = "WARN" if state != "CRIT" else state
            messages.append("Offset %f ms >= %f ms warning threshold" % (offset, warn_offset))

    if address and stratum != None:
        if stratum >= crit_stratum:
            state = "CRIT" if state == "OK" else state
            messages.append("Stratum %d >= %d critical threshold" % (stratum, crit_stratum))

    summary = "OK"
    if state == "OK":
        summary = "Offset: %f ms, Stratum: %d" % (offset if offset != None else 0, stratum if stratum != None else 0)
    else:
        summary = "; ".join(messages)

    metrics = {}
    if offset != None:
        metrics["offset"] = offset
    if stratum != None:
        metrics["stratum"] = stratum

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
