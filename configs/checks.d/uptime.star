def main(ctx, params):
    # Discovery mode: single-service check, no items
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": ["uptime"]}
                ]
            },
        }

    # Check mode: single item (item == "")
    # Read /proc/uptime on Linux, fallback to 'uptime' command elsewhere
    if ctx.facts().get("os_family") == "redhat" or ctx.facts().get("os_family") == "debian":
        # Linux: /proc/uptime contains "up_time_in_seconds seconds_idle"
        uptime_str = ctx.file_read("/proc/uptime").split()[0]
        uptime_sec = float(uptime_str)
    else:
        # Fallback: parse 'uptime' command output (GNU/Linux, BSD, macOS)
        res = ctx.run(["uptime"], mutates=False)
        output = res.stdout.strip()
        # Pattern: " 2:30pm  up  5:45,  3 users,  load average: 0.01, 0.05, 0.01"
        # or " 2:30pm  up 2 days,  5:45, ..."
        # Try to extract "up N time" or "up N day(s), N hr(s)" etc.
        up_match = output.find("up")
        if up_match == -1:
            fail("cannot parse uptime command output")
        # Extract substring starting after 'up'
        after_up = output[up_match + 2:].strip()
        # Use regex-free string parsing: split and scan
        parts = after_up.split()
        days = 0
        hrs = 0
        mins = 0
        i = 0
        while i < len(parts):
            if parts[i].isdigit():
                num = int(parts[i])
                if i + 1 < len(parts):
                    if parts[i + 1].startswith("day"):
                        days = num
                        i += 2
                        continue
                    elif parts[i + 1].startswith("hr") or parts[i + 1].startswith("hrs"):
                        hrs = num
                        i += 2
                        continue
                    elif parts[i + 1].startswith("min"):
                        mins = num
                        i += 2
                        continue
            # Handle colon time: HH:MM
            if parts[i].find(":") != -1:
                hm = parts[i].split(":")
                if len(hm) == 2:
                    if hm[0].isdigit() and hm[1].isdigit():
                        hrs = int(hm[0])
                        mins = int(hm[1])
                        i += 1
                        continue
            i += 1
        uptime_sec = 86400 * days + 3600 * hrs + 60 * mins

    # Convert to days/hours/mins for human readable message
    days = int(uptime_sec // 86400)
    hours = int((uptime_sec % 86400) // 3600)
    minutes = int((uptime_sec % 3600) // 60)
    msg_parts = []
    if days:
        msg_parts.append("%d day%s" % (days, "s" if days != 1 else ""))
    if hours:
        msg_parts.append("%d hour%s" % (hours, "s" if hours != 1 else ""))
    if minutes:
        msg_parts.append("%d min%s" % (minutes, "s" if minutes != 1 else ""))
    msg = "Uptime: %s" % (", ".join(msg_parts) if msg_parts else "0 minutes")

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": {"uptime": uptime_sec},
            "details": ""
        },
    }
