def main(ctx, params):
    # Try to read from standard paths for vms_queuejobs data
    path = ""
    if ctx.file_exists("/var/lib/yolo-man/vms_queuejobs"):
        path = "/var/lib/yolo-man/vms_queuejobs"
    elif ctx.file_exists("/proc/vms/queuejobs"):
        path = "/proc/vms/queuejobs"
    else:
        return {
            "changed": False,
            "msg": "No data available for vms_queuejobs",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "File not found",
            },
        }

    content = ctx.file_read(path)
    lines = content.split("\n")
    section = []
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        parts = stripped.split()
        if len(parts) >= 7:
            section.append(parts)

    names = []
    max_cpu_secs = 0.0
    max_cpu_job = None
    for entry in section:
        if len(entry) < 7:
            continue
        _id, name, _state, cpu_days_str, cpu_time, _ios, _pgfaults = entry[:7]
        names.append(name)
        
        # Parse cpu_time "HH:MM:SS.SS"
        time_parts = cpu_time.split(":")
        if len(time_parts) < 3:
            continue
        
        # Safe parsing of hours, minutes, seconds
        hours = 0.0
        minutes = 0.0
        seconds = 0.0
        h_part = time_parts[0]
        m_part = time_parts[1]
        s_part = time_parts[2]
        
        # Check if parts are valid numbers
        h_digits = h_part.replace(".", "")
        m_digits = m_part.replace(".", "")
        s_digits = s_part.replace(".", "")
        
        if h_digits.isdigit() or (h_digits.find(".") >= 0 and h_digits.replace(".", "").isdigit()):
            hours = float(h_part)
        if m_digits.isdigit() or (m_digits.find(".") >= 0 and m_digits.replace(".", "").isdigit()):
            minutes = float(m_part)
        if s_digits.isdigit() or (s_digits.find(".") >= 0 and s_digits.replace(".", "").isdigit()):
            seconds = float(s_part)
        
        # Parse cpu_days
        cpu_days = 0
        if cpu_days_str.isdigit():
            cpu_days = int(cpu_days_str)
        elif cpu_days_str.replace(".", "").isdigit():
            cpu_days = int(float(cpu_days_str))
        
        cpu_secs = cpu_days * 86400 + hours * 3600 + minutes * 60 + seconds
        if cpu_secs > max_cpu_secs:
            max_cpu_secs = cpu_secs
            max_cpu_job = name

    infotext = str(len(section)) + " jobs"
    if max_cpu_job != None:
        # Manual divmod: minutes, seconds = divmod(seconds_total, 60)
        total_seconds = max_cpu_secs
        minutes = int(total_seconds) // 60
        seconds = int(total_seconds) % 60
        total_minutes = minutes
        hours_val = total_minutes // 60
        minutes = total_minutes % 60
        total_hours = hours_val
        days = total_hours // 24
        hours_val = total_hours % 24
        
        ms = int((max_cpu_secs - int(max_cpu_secs)) * 100)
        infotext += (
            ", most CPU used by " + max_cpu_job +
            " (" + str(int(days)) + " days, " +
            "%d:%d:%d.%d" % (int(hours_val), int(minutes), int(seconds), ms) + ")"
        )

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }