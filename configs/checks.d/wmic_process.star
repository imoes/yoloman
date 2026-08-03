# Constants for metric names
# Memory conversion: bytes to MB
BYTES_PER_MB = 1048576.0
# Clock ticks to seconds (sysconf SC_CLK_TCK is typically 100 on Linux)
CLK_TCK = 100.0
# CPU percentage scaling: user/kernel time is in 100ns units in WMIC,
# but in /proc it's in clock ticks; we need rate per second
# In WMIC, times are in 100-nanosecond intervals, so dividing by 100000 gives seconds
# On Linux /proc, times are in seconds (ticks / CLK_TCK)

def _read_proc_file(ctx, path):
    exists = ctx.file_exists(path)
    if not exists:
        return None
    content = ctx.file_read(path)
    return content

def _read_proc_dir(ctx, path):
    res = ctx.run(["ls", "-1", path], mutates=False)
    if res.rc != 0:
        return []
    lines = res.stdout.splitlines()
    pids = []
    for line in lines:
        line = line.strip()
        if line and line.isdigit():
            pids.append(line)
    return pids

def _get_cpu_cores(ctx):
    # Count processor entries in /proc/cpuinfo to find number of cores
    content = _read_proc_file(ctx, "/proc/cpuinfo")
    if content == None:
        return 1
    count = 0
    for line in content.splitlines():
        if line.strip().startswith("processor"):
            count += 1
    return count if count > 0 else 1

def _get_proc_stat_fields(ctx, pid):
    content = _read_proc_file(ctx, "/proc/" + pid + "/stat")
    if content == None:
        return None
    # The stat file format: pid (comm) state ppid ... 
    # We need to handle comm which may contain spaces/parens
    # Find the last ')' to split safely
    last_paren = content.rfind(")")
    if last_paren == -1:
        return None
    before_comm = content[:content.find("(")]
    comm_part = content[content.find("(")+1:last_paren]
    comm = comm_part
    rest = content[last_paren+2:]  # after ") "
    fields = rest.split()
    # Now fields[0] is state, fields[1] is ppid, etc.
    # We need: utime (field 11, index 11 in rest split, but let's count from after comm)
    # In the rest (after comm), index 0=state, 1=ppid, 2=pgrp, ... 
    # utime is at position 11 (0-indexed from rest[2] onward, but rest includes state)
    # Full field layout after pid(comm): state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt
    # utime stime cutime cstime priority nice num_threads itrealvalue starttime
    # So in rest: [0]=state [1]=ppid [2]=pgrp [3]=session [4]=tty_nr [5]=tpgid [6]=flags
    # [7]=minflt [8]=cminflt [9]=majflt [10]=cmajflt [11]=utime [12]=stime
    if len(fields) < 13:
        return None
    utime = int(fields[11]) if fields[11].isdigit() else 0
    stime = int(fields[12]) if fields[12].isdigit() else 0
    # ThreadCount is not directly in stat, but /proc/<pid>/stat field 19 (num_threads)
    # Actually in rest: [18]=num_threads (0-indexed: state=0, so 19-1=18)
    num_threads = 0
    if len(fields) > 18 and fields[18].isdigit():
        num_threads = int(fields[18])
    return {
        "comm": comm,
        "utime": utime,
        "stime": stime,
        "num_threads": num_threads,
    }

def _get_proc_status_values(ctx, pid):
    content = _read_proc_file(ctx, "/proc/" + pid + "/status")
    if content == None:
        return {"WorkingSetSize": 0, "PageFileUsage": 0}
    rss_kb = 0
    vm_size_kb = 0
    for line in content.splitlines():
        if line.startswith("VmRSS:"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                rss_kb = int(parts[1])
        elif line.startswith("VmSize:"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                vm_size_kb = int(parts[1])
    # WorkingSetSize is RSS in bytes
    working_set = rss_kb * 1024
    # PageFileUsage is harder to map exactly; use VmSize as a proxy for virtual memory
    page_file = vm_size_kb * 1024
    return {"WorkingSetSize": working_set, "PageFileUsage": page_file}

def _get_process_name(ctx, pid):
    content = _read_proc_file(ctx, "/proc/" + pid + "/comm")
    if content == None:
        return None
    return content.strip()

def _read_all_processes(ctx):
    """Read all processes from /proc, returning list of dicts with the fields
    that the WMIC check expects: Name, WorkingSetSize, PageFileUsage,
    UserModeTime, KernelModeTime, ThreadCount."""
    pids = _read_proc_dir(ctx, "/proc")
    processes = []
    for pid in pids:
        stat = _get_proc_stat_fields(ctx, pid)
        if stat == None:
            continue
        name = stat["comm"]
        if name == None or name == "":
            continue
        status = _get_proc_status_values(ctx, pid)
        processes.append({
            "Name": name,
            "WorkingSetSize": status["WorkingSetSize"],
            "PageFileUsage": status["PageFileUsage"],
            "UserModeTime": stat["utime"],
            "KernelModeTime": stat["stime"],
            "ThreadCount": stat["num_threads"],
        })
    return processes

def _compute_state(value, warn, crit, higher_is_worse):
    """Compute OK/WARN/CRIT based on thresholds.
    higher_is_worse=True: WARN if value>=warn, CRIT if value>=crit
    higher_is_worse=False: WARN if value<=warn, CRIT if value<=crit"""
    if higher_is_worse:
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
    else:
        if value <= crit:
            return "CRIT"
        if value <= warn:
            return "WARN"
    return "OK"

def _worst_state(s1, s2):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(s1, 3) >= order.get(s2, 3):
        return s1
    return s2

def main(ctx, params):
    # Discovery mode: This check is enforced/manual, yields nothing
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "Process checks are enforced/manual services",
            "data": {"discovery": []},
        }

    # Check mode
    # Probe for the real source: /proc must exist
    proc_exists = ctx.file_exists("/proc")
    if not proc_exists:
        return {
            "changed": False,
            "msg": "no /proc filesystem found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    name = params.get("name", "")
    if name == None or name == "":
        return {
            "changed": False,
            "msg": "no process name configured",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Get thresholds from params with Checkmk defaults
    def _extract_levels(key, default):
        val = params.get(key)
        if val == None:
            return default
        # Could be ("fixed", (warn, crit)) or a simple tuple
        if type(val) == "list":
            if len(val) == 2 and type(val[0]) == "string" and val[0] == "fixed":
                inner = val[1]
                if type(inner) == "list" and len(inner) >= 2:
                    return (float(inner[0]), float(inner[1]))
            if len(val) == 2:
                return (float(val[0]), float(val[1]))
        elif type(val) == "string":
            decoded = json.decode(val) if val else None
            if decoded != None:
                return _extract_levels(decoded, default)
        return default

    mem_warn, mem_crit = _extract_levels("mem_levels", (0.0, 0.0))
    page_warn, page_crit = _extract_levels("page_levels", (0.0, 0.0))
    cpu_warn, cpu_crit = _extract_levels("cpu_levels", (0.0, 0.0))

    # Read all processes from /proc
    processes = _read_all_processes(ctx)

    # Count processes matching the name, and accumulate resource usage
    count = 0
    mem = 0
    page = 0
    userc = 0
    kernelc = 0
    cpucores = _get_cpu_cores(ctx)

    for psinfo in processes:
        if psinfo["Name"] == None:
            continue
        # ThreadCount for "System Idle Process" maps to CPU cores
        # On Linux, there's no "System Idle Process", but we can use
        # /proc/stat's idle or just count cores
        if psinfo["Name"].lower() == "system idle process":
            cpucores = psinfo["ThreadCount"] if psinfo["ThreadCount"] > 0 else cpucores
        elif psinfo["Name"].lower() == name.lower():
            count += 1
            mem += psinfo["WorkingSetSize"]
            page += psinfo["PageFileUsage"]
            userc += psinfo["UserModeTime"]
            kernelc += psinfo["KernelModeTime"]

    # Compute metrics
    mem_mb = mem / BYTES_PER_MB
    page_mb = page / BYTES_PER_MB

    # For CPU: in WMIC, times are in 100ns intervals, rate gives per-second
    # then /100000 to get to seconds, /cpucores for per-core percentage
    # On Linux, /proc/<pid>/stat gives clock ticks; / CLK_TCK gives seconds
    # Rate would need time delta, but since we can't easily do get_rate,
    # we compute instantaneous CPU usage from total time / uptime
    # Actually, let's compute it differently: read /proc/<pid>/stat once,
    # and compute CPU% as (utime + stime) / (uptime * CLK_TCK) * 100
    # This gives average CPU% since process start

    # Since we can't easily maintain state between checks (no value_store in our runtime),
    # we'll compute an approximation using process start time and uptime
    # Read uptime
    uptime_content = _read_proc_file(ctx, "/proc/uptime")
    uptime = 1.0
    if uptime_content != None:
        parts = uptime_content.split()
        if len(parts) >= 1:
            uptime = float(parts[0]) if parts[0] else 1.0

    # userc and kernelc are in clock ticks; total seconds = (utime + stime) / CLK_TCK
    total_cpu_time_sec = (userc + kernelc) / CLK_TCK
    # CPU percentage = total_cpu_time / uptime * 100
    if uptime > 0 and cpucores > 0:
        cpu_perc = (total_cpu_time_sec / uptime) * 100.0
        user_perc = ((userc / CLK_TCK) / uptime) * 100.0 if uptime > 0 else 0.0
        kernel_perc = ((kernelc / CLK_TCK) / uptime) * 100.0 if uptime > 0 else 0.0
    else:
        cpu_perc = 0.0
        user_perc = 0.0
        kernel_perc = 0.0

    # Build messages
    messages = ["%d processes" % count]
    state = "OK"

    msg = "%f%%/%f%% User/Kernel" % (user_perc, kernel_perc)
    if cpu_perc >= cpu_crit:
        state = "CRIT"
        msg += "(!!) (critical at %f%%)" % cpu_crit
    elif cpu_perc >= cpu_warn:
        state = "WARN"
        msg += "(!) (warning at %f%%)" % cpu_warn
    messages.append(msg)

    msg = "%fMB RAM" % mem_mb
    if (0 < mem_crit) and (mem_crit <= mem_mb):
        state = "CRIT"
        msg += "(!!) (critical at %s MB)" % mem_crit
    elif (0 < mem_warn) and (mem_warn <= mem_mb):
        state = _worst_state(state, "WARN")
        msg += "(!) (warning at %s MB)" % mem_warn
    messages.append(msg)

    msg = "%fMB Page" % page_mb
    if page_mb >= page_crit:
        state = "CRIT"
        msg += "(!!) (critical at %s MB)" % page_crit
    elif page_mb >= page_warn:
        state = _worst_state(state, "WARN")
        msg += "(!) (warning at %s MB)" % page_warn
    messages.append(msg)

    combined_msg = ", ".join(messages)

    details = "Name: %s\n" % name
    details += "Count: %d\n" % count
    details += "Memory: %f MB\n" % mem_mb
    details += "Page File: %f MB\n" % page_mb
    details += "User CPU: %f%%\n" % user_perc
    details += "Kernel CPU: %f%%\n" % kernel_perc
    details += "CPU Cores: %d\n" % cpucores

    metrics = {
        "mem": mem_mb,
        "page": page_mb,
        "user": user_perc,
        "kernel": kernel_perc,
    }

    return {
        "changed": False,
        "msg": combined_msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }