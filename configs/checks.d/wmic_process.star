def main(ctx, params):
    name = params.get("name", "")
    if name == None:
        name = ""

    mem_levels = params.get("mem_levels")
    page_levels = params.get("page_levels")
    cpu_levels = params.get("cpu_levels")

    def extract_levels(levels):
        if levels == None:
            return (0.0, 0.0)
        if type(levels) != "list" or len(levels) != 2:
            return (0.0, 0.0)
        if type(levels[0]) != "string" or levels[0] != "fixed":
            return (0.0, 0.0)
        fixed = levels[1]
        if type(fixed) != "list" or len(fixed) != 2:
            return (0.0, 0.0)
        w_str = fixed[0]
        c_str = fixed[1]
        w = float(w_str) if type(w_str) == "string" or type(w_str) == "float" else 0.0
        c = float(c_str) if type(c_str) == "string" or type(c_str) == "float" else 0.0
        return (w, c)

    memwarn, memcrit = extract_levels(mem_levels)
    pagewarn, pagecrit = extract_levels(page_levels)
    cpuwarn, cpucrit = extract_levels(cpu_levels)

    res = ctx.run([
        "wmic", "process", "get",
        "Name,WorkingSetSize,PageFileUsage,UserModeTime,KernelModeTime,ThreadCount",
        "/format:csv"
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "wmic command failed", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": "wmic command failed: " + res.stderr
        }}

    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {"changed": False, "msg": "no process data", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": "wmic returned no data"
        }}

    header_line = ""
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        if stripped.startswith("#"):
            continue
        header_line = stripped
        break

    if header_line == "":
        return {"changed": False, "msg": "no header line", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": "could not find header line"
        }}

    header_cols = header_line.split(",")
    idx_name = -1
    idx_mem = -1
    idx_page = -1
    idx_user = -1
    idx_kernel = -1
    idx_threads = -1

    for i, col in enumerate(header_cols):
        c = col.strip()
        if c == "Name":
            idx_name = i
        elif c == "WorkingSetSize":
            idx_mem = i
        elif c == "PageFileUsage":
            idx_page = i
        elif c == "UserModeTime":
            idx_user = i
        elif c == "KernelModeTime":
            idx_kernel = i
        elif c == "ThreadCount":
            idx_threads = i

    if idx_name == -1 or idx_mem == -1 or idx_page == -1 or idx_user == -1 or idx_kernel == -1:
        return {"changed": False, "msg": "wmic output missing expected columns", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": "wmic header missing expected columns"
        }}

    count = 0
    mem = 0
    page = 0
    userc = 0
    kernelc = 0
    cpucores = 1

    header_found = False
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        if stripped.startswith("#"):
            continue
        if not header_found:
            header_found = True
            continue
        parts = stripped.split(",")
        if len(parts) < max(idx_name, idx_mem, idx_page, idx_user, idx_kernel) + 1:
            continue

        name_val = parts[idx_name].strip() if len(parts) > idx_name else ""
        if name_val == "":
            continue
        if idx_threads != -1 and name_val.lower() == "system idle process":
            if len(parts) > idx_threads:
                t = parts[idx_threads].strip()
                if t.isdigit():
                    cpucores = int(t)
                    if cpucores <= 0:
                        cpucores = 1
            continue

        if name_val.lower() == name.lower():
            count += 1
            if len(parts) > idx_mem:
                mem_str = parts[idx_mem].strip()
                mem += int(mem_str) if mem_str.isdigit() else 0
            if len(parts) > idx_page:
                page_str = parts[idx_page].strip()
                page += int(page_str) if page_str.isdigit() else 0
            if len(parts) > idx_user:
                user_str = parts[idx_user].strip()
                userc += int(user_str) if user_str.isdigit() else 0
            if len(parts) > idx_kernel:
                kernel_str = parts[idx_kernel].strip()
                kernelc += int(kernel_str) if kernel_str.isdigit() else 0

    if name == "":
        return {"changed": False, "msg": "no process name specified", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": "parameter 'name' is required"
        }}

    mem_mb = mem / 1048576.0
    page_mb = page / 1048576.0
    user_per_sec = (userc / 100000.0) / cpucores
    kernel_per_sec = (kernelc / 100000.0) / cpucores
    user_perc = user_per_sec
    kernel_perc = kernel_per_sec
    cpu_perc = user_perc + kernel_perc

    messages = [str(count) + " processes"]
    state = "OK"

    msg = "%f%%/%f%% User/Kernel" % (user_perc, kernel_perc)
    if cpu_perc >= cpucrit:
        state = "CRIT"
        msg += " (critical at %f%%)" % cpucrit
    elif cpu_perc >= cpuwarn:
        state = "WARN"
        msg += " (warning at %f%%)" % cpuwarn
    messages.append(msg)

    msg = "%fMB RAM" % mem_mb
    if memcrit > 0 and mem_mb >= memcrit:
        state = "CRIT"
        msg += " (critical at %f MB)" % memcrit
    elif memwarn > 0 and mem_mb >= memwarn:
        if state != "CRIT":
            state = "WARN"
        msg += " (warning at %f MB)" % memwarn
    messages.append(msg)

    msg = "%fMB Page" % page_mb
    if page_mb >= pagecrit:
        state = "CRIT"
        msg += " (critical at %f MB)" % pagecrit
    elif page_mb >= pagewarn:
        if state != "CRIT":
            state = "WARN"
        msg += " (warning at %f MB)" % pagewarn
    messages.append(msg)

    return {"changed": False, "msg": ", ".join(messages), "data": {
        "state": state,
        "metrics": {
            "mem": mem_mb,
            "page": page_mb,
            "user": user_perc,
            "kernel": kernel_perc
        },
        "details": ""
    }}