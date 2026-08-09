def main(ctx, params):
    if params.get("_discover"):
        # Probe for /proc/stat — the real data source
        stat = ctx.run(["cat", "/proc/stat"], mutates=False)
        if stat.rc != 0 or not stat.stdout:
            return {"changed": False, "msg": "no /proc/stat", "data": {"discovery": [], "host_labels": {}}}
        cpu_lines = []
        for line in stat.stdout.splitlines():
            f = line.split()
            if len(f) < 1:
                continue
            if f[0] == "cpu" or (f[0].startswith("cpu") and len(f[0]) > 3):
                cpu_lines.append(f)
        if len(cpu_lines) == 0:
            return {"changed": False, "msg": "no cpu lines", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "discovered CPU utilization", "data": {"discovery": [{"item": "", "params": {}, "metrics": ["utilization"]}]}}
    item = params.get("item", "")
    stat = ctx.run(["cat", "/proc/stat"], mutates=False)
    if stat.rc != 0 or not stat.stdout:
        return {"changed": False, "msg": "no /proc/stat", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    cpu_total = None
    cpu_cores = []
    for line in stat.stdout.splitlines():
        f = line.split()
        if len(f) < 1:
            continue
        if f[0] == "cpu":
            cpu_total = f
        elif f[0].startswith("cpu") and len(f[0]) > 3:
            cpu_cores.append(f)
    if cpu_total == None or len(cpu_total) < 5:
        return {"changed": False, "msg": "No line with CPU info found.", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Parse CPU counters; values are in USER_HZ (typically 1/100s)
    def to_int(s):
        return int(s) if s.isdigit() else 0
    user = to_int(cpu_total[1])
    nice = to_int(cpu_total[2])
    system = to_int(cpu_total[3])
    idle = to_int(cpu_total[4])
    iowait = to_int(cpu_total[5]) if len(cpu_total) > 5 else 0
    irq = to_int(cpu_total[6]) if len(cpu_total) > 6 else 0
    softirq = to_int(cpu_total[7]) if len(cpu_total) > 7 else 0
    steal = to_int(cpu_total[8]) if len(cpu_total) > 8 else 0
    guest = to_int(cpu_total[9]) if len(cpu_total) > 9 else 0
    guest_nice = to_int(cpu_total[10]) if len(cpu_total) > 10 else 0
    # Compute idle and total
    idle_all = idle + iowait
    total_all = user + nice + system + idle + iowait + irq + softirq + steal
    # Apply guest adjustments (guest is already counted in user/nice)
    total_all = total_all - guest if total_all >= guest else 0
    user = user - guest if user >= guest else 0
    nice = nice - guest_nice if nice >= guest_nice else 0
    # Utilization = 100 * (total - idle) / total
    if total_all == 0:
        utilization = 0.0
    else:
        utilization = 100.0 * (total_all - idle_all) / total_all
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    # Upper levels: WARN if >= warn, CRIT if >= crit
    if utilization >= crit:
        state = "CRIT"
    elif utilization >= warn:
        state = "WARN"
    else:
        state = "OK"
    msg = "Utilization %f%%" % utilization
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"utilization": utilization}, "details": ""}}