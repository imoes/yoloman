def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["vss_list", "--veeam-clients"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "veeam not installed", "data": {"discovery": []}}
        section = parse_section(res.stdout)
        out = []
        for job in section:
            out.append({"item": job, "params": {"age": (108000, 172800)}, "metrics": ["totalsize", "readsize", "transferredsize", "duration", "avgspeed"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["vss_list", "--veeam-clients"], mutates=False)
    if res.rc == 127 or not res.stdout:
        return {"changed": False, "msg": "veeam not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = parse_section(res.stdout)
    if item not in section:
        return {"changed": False, "msg": "Client not found in agent output", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = section[item]
    infotexts = []
    state = "OK"
    if data.get("Status") == "Warning":
        state = "WARN"
    if data.get("Status") == "Failed":
        state = "CRIT"
    infotexts.append("Status: %s" % data.get("Status", ""))
    if data.get("JobName"):
        infotexts.append("Job: %s" % data["JobName"])
    size_info = []
    size_legend = []
    metrics = {}
    total_size_byte = to_int(data.get("TotalSizeByte"))
    metrics["totalsize"] = total_size_byte
    size_info.append(format_bytes(total_size_byte))
    size_legend.append("total")
    if "ReadSizeByte" in data:
        read_size_byte = to_int(data["ReadSizeByte"])
        metrics["readsize"] = read_size_byte
        size_info.append(format_bytes(read_size_byte))
        size_legend.append("read")
    if "TransferedSizeByte" in data:
        transfered_size_byte = to_int(data["TransferedSizeByte"])
        metrics["transferredsize"] = transfered_size_byte
        size_info.append(format_bytes(transfered_size_byte))
        size_legend.append("transferred")
    infotexts.append("Size (%s): %s" % ("/".join(size_legend), "/ ".join(size_info)))
    if data.get("Status") not in ["InProgress", "Pending"]:
        age_levels = params.get("age", [108000, 172800])
        warn = age_levels[0]
        crit = age_levels[1]
        age = None
        if data.get("LastBackupAge") != None:
            age = to_float(data["LastBackupAge"])
        elif data.get("StopTime") != None:
            stop_time = data["StopTime"]
            if stop_time != "01.01.1900 00:00:00":
                age = compute_age_seconds(ctx, stop_time)
        if age != None:
            label = ""
            levels = " (Warn/Crit: %s/%s)" % (format_timespan(warn), format_timespan(crit))
            if age >= crit:
                state = worst_state(state, "CRIT")
                label = "(!!)"
            elif age >= warn:
                state = worst_state(state, "WARN")
                label = "(!)"
            if label:
                infotexts.append("Last backup: %s ago%s%s" % (format_timespan_int(age), label, levels))
        else:
            infotexts.append("No complete Backup(!!)")
            state = worst_state(state, "CRIT")
        if data.get("DurationDDHHMMSS"):
            duration = parse_duration(data["DurationDDHHMMSS"])
            infotexts.append("Duration: %s" % format_timespan(duration))
            metrics["duration"] = duration
    if "AvgSpeedBps" in data:
        avg_speed_bps = to_int(data["AvgSpeedBps"])
        metrics["avgspeed"] = avg_speed_bps
        infotexts.append("Average Speed: %s" % format_iobandwidth(avg_speed_bps))
    if "BackupServer" in data:
        infotexts.append("Backup server: %s" % data["BackupServer"])
    return {"changed": False, "msg": ", ".join(infotexts), "data": {"state": state, "metrics": metrics, "details": ""}}


def parse_section(output_lines):
    section = {}
    last_status = False
    last_found = ""
    for line in output_lines.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        if parts[0] == "Status":
            if len(parts) == 2:
                last_status = parts[1]
            else:
                last_status = False
        elif parts[0] == "JobName":
            if last_status:
                last_found = parts[1]
                section[last_found] = {}
                section[last_found]["Status"] = str(last_status)
        elif last_status and len(parts) == 2:
            if last_found != "":
                section[last_found][parts[0]] = parts[1]
    return section


def to_int(v):
    if v == None:
        return 0
    s = str(v)
    return int(s) if s.isdigit() else 0


def _pow(b, e):
    if e < 0:
        return 0
    result = 1
    i = 0
    while i < e:
        result = result * b
        i = i + 1
    return result


def to_float(v):
    if v == None:
        return 0
    s = str(v)
    neg = s.startswith("-")
    body = s[1:] if neg else s
    if body == "":
        return 0
    parts = body.split(".")
    intpart = parts[0]
    if intpart == "" or not intpart.isdigit():
        return 0
    if len(parts) > 2:
        return 0
    fracpart = parts[1] if len(parts) > 1 else ""
    if fracpart != "" and not fracpart.isdigit():
        return 0
    val = int(intpart)
    if len(parts) > 1:
        frac = 0
        for i in range(len(fracpart)):
            frac = frac * 10 + (ord(fracpart[i]) - 48)
        val = val + frac / _pow(10, len(fracpart))
    return -val if neg else val


def compute_age_seconds(ctx, stop_time):
    parts = stop_time.split(" ")
    if len(parts) != 2:
        return None
    d = parts[0].split(".")
    t = parts[1].split(":")
    if len(d) != 3 or len(t) != 3:
        return None
    day = to_int(d[0])
    month = to_int(d[1])
    year = to_int(d[2])
    hour = to_int(t[0])
    minute = to_int(t[1])
    second = to_int(t[2])
    epoch = ctx.time_mktime(year, month, day, hour, minute, second)
    if epoch == None:
        return None
    now = ctx.time_now()
    return now - epoch


def format_bytes(b):
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    if b == 0:
        return "0 B"
    u = 0
    size = float(b)
    while size >= 1024 and u < len(units) - 1:
        size = size / 1024
        u = u + 1
    if u == 0:
        return "%d %s" % (b, units[u])
    return "%f %s" % (size, units[u])


def format_timespan(seconds):
    seconds = int(seconds)
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    if days > 0:
        return "%dd %dh %dm" % (days, hours, minutes)
    if hours > 0:
        return "%dh %dm %ds" % (hours, minutes, secs)
    if minutes > 0:
        return "%dm %ds" % (minutes, secs)
    return "%ds" % secs


def format_timespan_int(seconds):
    return format_timespan(int(seconds))


def format_iobandwidth(bps):
    units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
    if bps == 0:
        return "0 B/s"
    u = 0
    size = float(bps)
    while size >= 1024 and u < len(units) - 1:
        size = size / 1024
        u = u + 1
    if u == 0:
        return "%d %s" % (bps, units[u])
    return "%f %s" % (size, units[u])


def parse_duration(s):
    parts = s.split(":")
    if len(parts) != 4:
        return 0
    days = to_int(parts[0])
    hours = to_int(parts[1])
    minutes = to_int(parts[2])
    seconds = to_int(parts[3])
    return seconds + minutes * 60 + hours * 3600 + days * 86400


def worst_state(a, b):
    rank = {"OK": 0, "UNKNOWN": 1, "WARN": 2, "CRIT": 3}
    if rank.get(a, 0) >= rank.get(b, 0):
        return a
    return b