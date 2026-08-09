def main(ctx, params):
    name = params.get("name")
    pattern = params.get("pattern")
    ignore_case = params.get("ignore_case", False)

    if name == None and pattern == None:
        fail("One of name or pattern is required")
    if name != None and pattern != None:
        fail("Cannot specify both name and pattern")

    facts = ctx.facts()
    os_family = facts.get("os_family", "").lower()

    if os_family == "redhat" or os_family == "debian" or facts.get("distribution", "").lower() == "ubuntu":
        res = ctx.run(["ps", "-eo", "pid,comm", "-ww"], mutates=False)
    else:
        res = ctx.run(["ps", "-eo", "pid,comm"], mutates=False)

    if res.rc != 0:
        fail("Failed to retrieve process list: " + res.stderr)

    lines = res.stdout.split("\n")
    if len(lines) > 0 and lines[0].strip().startswith("PID"):
        lines = lines[1:]

    pids = []
    i = 0
    while i < len(lines):
        line = lines[i]
        i = i + 1
        if line.strip() == "":
            continue
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        pid_str, proc_name = parts[0], parts[1]

        pid = int(pid_str)

        match = False
        if name != None:
            if ignore_case:
                match = proc_name.lower().find(name.lower()) != -1 or proc_name.startswith(name)
            else:
                match = proc_name.find(name) != -1 or proc_name == name
        else:
            if ignore_case:
                match = proc_name.lower().find(pattern.lower()) != -1
            else:
                match = proc_name.find(pattern) != -1

        if match:
            pids.append(pid)

    return {"changed": False, "pids": pids}
