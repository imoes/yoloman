def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["timedatectl", "status"], mutates=False)
        has_timesyncd = False
        if "NTP service: active" in res.stdout.lower() or "systemd-timesyncd" in res.stdout.lower():
            has_timesyncd = True
        if has_timesyncd:
            return {
                "changed": False,
                "msg": "discovered Systemd Timesyncd Time service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": [
                    "time_offset", "last_sync_time", "last_sync_receive_time",
                    "stratum", "jitter"
                ]}]}
            }
        return {
            "changed": False,
            "msg": "discovered 0 items (systemd-timesyncd not active)",
            "data": {"discovery": []}
        }

    # Check mode - get data via timedatectl status
    res = ctx.run(["timedatectl", "status"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to get timedatectl status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Default parameters (Checkmk defaults)
    stratum_level = params.get("stratum_level", 10)
    quality_levels = params.get("quality_levels", [200.0, 500.0])
    warn_quality = quality_levels[0] / 1000.0
    crit_quality = quality_levels[1] / 1000.0
    last_ntp_message = params.get("last_ntp_message", [3600, 7200])

    state = "OK"
    messages = []

    lines = res.stdout.splitlines()
    server = None
    stratum = None
    offset = None
    jitter = None
    synctime = None
    ntp_message_time = None

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("Server:") or stripped.startswith("NTP server:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val != "" and val != "(null)" and val != "none":
                    server = val
        elif stripped.startswith("Stratum:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val.isdigit():
                    stratum = int(val)
        elif stripped.startswith("Offset:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                val_parts = val.split()
                if len(val_parts) >= 1:
                    num_str = val_parts[0]
                    unit = "s"
                    if len(val_parts) >= 2:
                        unit = val_parts[1].lower()
                    num_val = 0.0
                    if num_str.replace(".", "").replace("-", "").isdigit() or num_str == "-" or num_str == ".":
                        num_val = float(num_str)
                    else:
                        digits = ""
                        for c in num_str:
                            if c.isdigit() or c == '.' or (c == '-' and digits == ""):
                                digits += c
                            else:
                                break
                        if digits != "" and digits != "-" and digits != ".":
                            num_val = float(digits)
                        else:
                            num_val = 0.0
                    if unit in ("ms", "msec"):
                        num_val = num_val / 1000.0
                    elif unit in ("us", "µs", "usec"):
                        num_val = num_val / 1000000.0
                    offset = num_val
        elif stripped.startswith("Jitter:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                val_parts = val.split()
                if len(val_parts) >= 1:
                    num_str = val_parts[0]
                    unit = "s"
                    if len(val_parts) >= 2:
                        unit = val_parts[1].lower()
                    num_val = 0.0
                    if num_str.replace(".", "").replace("-", "").isdigit() or num_str == "-" or num_str == ".":
                        num_val = float(num_str)
                    else:
                        digits = ""
                        for c in num_str:
                            if c.isdigit() or c == '.' or (c == '-' and digits == ""):
                                digits += c
                            else:
                                break
                        if digits != "" and digits != "-" and digits != ".":
                            num_val = float(digits)
                        else:
                            num_val = 0.0
                    if unit in ("ms", "msec"):
                        num_val = num_val / 1000.0
                    elif unit in ("us", "µs", "usec"):
                        num_val = num_val / 1000000.0
                    jitter = num_val
        elif stripped.startswith("Last sync time:"):
            parts = stripped.split(":", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                val = val.replace(" ago", "")
                if val.isdigit():
                    synctime = float(val)
                else:
                    total_seconds = 0
                    if "min" in val:
                        idx = val.find("min")
                        if idx >= 0:
                            before = val[:idx].strip()
                            digits = ""
                            for c in before:
                                if c.isdigit():
                                    digits += c
                                else:
                                    break
                            if digits != "":
                                total_seconds += int(digits) * 60
                    if "sec" in val:
                        idx = val.find("sec")
                        if idx >= 0:
                            before = val[:idx].strip()
                            digits = ""
                            for c in before:
                                if c.isdigit():
                                    digits += c
                                else:
                                    break
                            if digits != "":
                                total_seconds += int(digits)
                    if "h" in val:
                        idx = val.find("h")
                        if idx >= 0:
                            before = val[:idx].strip()
                            digits = ""
                            for c in before:
                                if c.isdigit():
                                    digits += c
                                else:
                                    break
                            if digits != "":
                                total_seconds += int(digits) * 3600
                    if "d" in val:
                        idx = val.find("d")
                        if idx >= 0:
                            before = val[:idx].strip()
                            digits = ""
                            for c in before:
                                if c.isdigit():
                                    digits += c
                                else:
                                    break
                            if digits != "":
                                total_seconds += int(digits) * 86400
                    if total_seconds > 0:
                        synctime = float(total_seconds)
        elif stripped.startswith("NTPMessage={"):
            idx = stripped.find("ReceiveTimestamp=")
            if idx >= 0:
                ts_part = stripped[idx + len("ReceiveTimestamp="):]
                ts_tokens = ts_part.split()
                if len(ts_tokens) >= 2:
                    date_part = ts_tokens[0]
                    time_part = ts_tokens[1]
                    if date_part.count("-") == 2:
                        parts = date_part.split("-")
                        if len(parts) == 3:
                            year = int(parts[0]) if parts[0].isdigit() else 0
                            month = int(parts[1]) if parts[1].isdigit() else 0
                            day = int(parts[2]) if parts[2].isdigit() else 0
                            if time_part.count(":") >= 2:
                                time_parts = time_part.split(":")
                                hour = int(time_parts[0]) if time_parts[0].isdigit() else 0
                                minute = int(time_parts[1]) if time_parts[1].isdigit() else 0
                                second_str = time_parts[2].split(".")[0]
                                second = int(second_str) if second_str.isdigit() else 0
                                days = (year - 1970) * 365 + (year - 1969) // 4
                                month_days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
                                days += month_days[month - 1] + day - 1
                                if month > 2 and (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)):
                                    days += 1
                                ntp_message_time = days * 86400 + hour * 3600 + minute * 60 + second

    # Check server presence
    if server == None or server == "":
        state = "CRIT"
        messages.append("Found no time server")
        return {
            "changed": False,
            "msg": "; ".join(messages),
            "data": {"state": state, "metrics": {}, "details": ""}
        }

    # Check offset
    metrics = {}
    if offset != None:
        abs_offset = abs(offset)
        if abs_offset >= crit_quality:
            state = "CRIT"
        elif abs_offset >= warn_quality:
            if state != "CRIT":
                state = "WARN"
        metrics["time_offset"] = abs_offset

    # Check last sync time
    if synctime != None:
        if synctime >= last_ntp_message[1]:
            if state != "CRIT":
                state = "CRIT"
        elif synctime >= last_ntp_message[0]:
            if state == "OK":
                state = "WARN"
        metrics["last_sync_time"] = synctime

    # Check NTP message receive time
    if ntp_message_time != None:
        if synctime == None:
            synctime = ntp_message_time
            if synctime >= last_ntp_message[1]:
                if state != "CRIT":
                    state = "CRIT"
            elif synctime >= last_ntp_message[0]:
                if state == "OK":
                    state = "WARN"
        metrics["last_sync_receive_time"] = synctime if synctime != None else 0

    # Check stratum
    if stratum != None:
        upper_stratum = stratum_level - 1
        if stratum > upper_stratum:
            if state == "OK":
                state = "WARN"
        metrics["stratum"] = stratum

    # Check jitter
    if jitter != None:
        if jitter >= crit_quality:
            if state != "CRIT":
                state = "CRIT"
        elif jitter >= warn_quality:
            if state == "OK":
                state = "WARN"
        metrics["jitter"] = jitter

    # Final summary
    summary = "Synchronized on %s" % server
    if state == "OK":
        summary = "Synchronized on %s" % server
    elif state == "WARN":
        summary = "Warning: " + summary
    elif state == "CRIT":
        summary = "Critical: " + summary

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }