def main(ctx, params):
    path = params["path"]
    state = params["state"]
    table = params.get("table")
    noflush = params.get("noflush", False)
    counters = params.get("counters", False)
    modprobe = params.get("modprobe")
    ip_version = params.get("ip_version", "ipv4")
    wait = params.get("wait")

    if state not in ("saved", "restored"):
        fail("unsupported state: " + state)
    if ip_version not in ("ipv4", "ipv6"):
        fail("unsupported ip_version: " + ip_version)

    bin_iptables = "iptables" if ip_version == "ipv4" else "ip6tables"
    bin_save = "iptables-save" if ip_version == "ipv4" else "ip6tables-save"
    bin_restore = "iptables-restore" if ip_version == "ipv4" else "ip6tables-restore"

    # Check binaries exist
    res = ctx.run(["which", bin_save])
    if res.rc != 0:
        fail(bin_save + " not found")
    res = ctx.run(["which", bin_restore])
    if res.rc != 0:
        fail(bin_restore + " not found")

    # Validate path exists for restore
    if state == "restored":
        if not ctx.file_exists(path):
            fail("Source " + path + " not found")
        # Ensure it's a regular file
        stat = ctx.stat(path)
        if stat == None or stat.get("is_dir", False):
            fail("Source " + path + " not a file")

    # Build command args
    cmd_args = []
    test_args = []

    if counters:
        cmd_args.extend(["--counters"])
        test_args.extend(["--counters"])

    if table != None:
        cmd_args.extend(["--table", table])
        test_args.extend(["--table", table])

    if wait != None:
        test_args.extend(["--wait", str(wait)])

    if modprobe != None:
        modprobe_path = ctx.run(["readlink", "-f", modprobe])
        if modprobe_path.rc != 0:
            fail("modprobe " + modprobe + " not found")
        # Check if it's a file and executable
        modprobe_stat = ctx.stat(modprobe)
        if modprobe_stat == None or modprobe_stat.get("is_dir", False):
            fail("modprobe " + modprobe + " not a file")
        # We assume modprobe is executable if present
        cmd_args.extend(["--modprobe", modprobe])
        test_args.extend(["--modprobe", modprobe])

    # Save command
    save_cmd = [bin_save] + cmd_args
    # Restore command
    restore_cmd = [bin_restore] + cmd_args
    if noflush:
        restore_cmd.append("--noflush")
    # Test command
    test_cmd = [bin_restore, "--test"] + test_args

    # Read initial state
    res = ctx.run([bin_save], mutates=False)
    if res.rc != 0:
        fail("failed to read initial state: " + res.stderr)

    initial_state_raw = res.stdout
    initial_state = _filter_and_format(initial_state_raw, counters)

    # Get table-specific state before operation
    tables_before = _per_table_state(bin_save, initial_state_raw, counters)

    # Save operation
    if state == "saved":
        cmd = " ".join(save_cmd)
        # Read existing file content to check for changes
        existing_content = ""
        if ctx.file_exists(path):
            existing_content = ctx.file_read(path)
        new_content = "\n".join(_filter_and_format(initial_state_raw, counters)) + "\n"

        changed = new_content != existing_content

        if changed and not ctx.check_mode:
            # Create parent directory if needed
            dir_path = "/".join(path.split("/")[:-1])
            if dir_path:
                ctx.run(["mkdir", "-p", dir_path], mutates=True)
            changed = ctx.file_write(path, new_content, mode="0644")

        return {
            "changed": changed,
            "msg": "saved iptables state to " + path,
            "data": {
                "cmd": cmd,
                "tables": tables_before,
                "initial_state": initial_state,
                "saved": initial_state,
            },
        }

    # Restore operation
    restore_content = ctx.file_read(path)
    state_to_restore = _filter_and_format(restore_content, counters)

    # Check that specified table exists in file if table is specified
    if table != None and ("*" + table) not in restore_content:
        fail("Table " + table + " to restore not defined in " + path)

    # Initialize if needed for empty state
    if not initial_state_raw.strip():
        # Initialize with default filter table if empty
        ctx.run([bin_iptables, "-L", "-n", "-t", "filter"], mutates=False)
        res = ctx.run([bin_save], mutates=False)
        initial_state_raw = res.stdout
        initial_state = _filter_and_format(initial_state_raw, counters)
        tables_before = _per_table_state(bin_save, initial_state_raw, counters)

    # Test restore before applying (to verify syntax)
    for t in tables_before.keys():
        if t not in ("filter", "mangle", "nat", "raw", "security"):
            continue
        testcommand = test_cmd + ["--table", t]
        # Extract relevant portion for this table
        table_content = _extract_table_content(restore_content, t)
        if not table_content:
            continue

        # Write to temp file for test
        tmpfile = "/tmp/iptables_state_test_" + t
        ctx.file_write(tmpfile, table_content + "\n")

        test_res = ctx.run(testcommand + [tmpfile], mutates=False)
        if test_res.rc != 0 and "Another app is currently holding the xtables lock" in test_res.stderr:
            fail(test_res.stderr)

    if ctx.check_mode:
        # In check_mode, check if restored content would differ
        # Just compare the relevant table(s)
        return {
            "changed": True,
            "msg": "would restore iptables state from " + path,
            "data": {
                "cmd": " ".join(restore_cmd),
                "tables": tables_before,
                "initial_state": initial_state,
                "restored": state_to_restore,
                "applied": True,
            },
        }

    # Perform actual restore
    tmpfile = "/tmp/iptables_state_restore"
    ctx.file_write(tmpfile, restore_content + "\n")
    res = ctx.run(restore_cmd + [tmpfile], mutates=True)

    if res.rc != 0:
        if "Another app is currently holding the xtables lock" in res.stderr:
            fail(res.stderr)
        fail("failed to restore iptables: " + res.stderr)

    # Read final state
    res = ctx.run([bin_save], mutates=False)
    restored_state_raw = res.stdout
    restored_state = _filter_and_format(restored_state_raw, counters)

    # Check for changes
    tables_after = _per_table_state(bin_save, restored_state_raw, counters)
    changed = tables_after != tables_before

    return {
        "changed": changed,
        "msg": "restored iptables state from " + path,
        "data": {
            "cmd": " ".join(restore_cmd),
            "tables": tables_before,
            "initial_state": initial_state,
            "restored": state_to_restore,
            "applied": True,
        },
    }


def _filter_and_format(content, counters):
    lines = []
    i = 0
    while i < len(content.splitlines()):
        line = content.splitlines()[i]
        if not line.strip():
            i += 1
            continue
        # Remove timestamps from generated/completed lines
        if line.startswith("# Generated") or line.startswith("# Completed"):
            idx = line.find(" on ")
            if idx != -1:
                line = line[:idx]
        # Remove counters if not requested
        if not counters:
            # Replace [digits:digits] with [0:0]
            new_line = ""
            j = 0
            while j < len(line):
                if line[j] == "[":
                    # Look for closing bracket
                    k = j + 1
                    while k < len(line) and line[k] != "]":
                        k += 1
                    if k < len(line):
                        # It's a counter
                        new_line += "[0:0]"
                        j = k + 1
                        continue
                new_line += line[j]
                j += 1
            line = new_line
        lines.append(line)
        i += 1
    return lines


def _per_table_state(bin_save, content, counters):
    tables = {}
    # Simple parsing to extract table sections
    current_table = None
    current_lines = []
    i = 0
    lines_list = content.splitlines()
    while i < len(lines_list):
        line = lines_list[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith("*"):
            if current_table != None:
                tables[current_table] = _format_table_lines(current_lines, counters)
            current_table = line[1:]
            current_lines = []
        elif line in ("COMMIT", "# Generated", "# Completed") or line.startswith("#"):
            if current_table != None:
                i += 1
                continue
        else:
            if current_table != None:
                current_lines.append(line)
        i += 1

    # Handle last table
    if current_table != None:
        tables[current_table] = _format_table_lines(current_lines, counters)

    return tables


def _format_table_lines(lines, counters):
    formatted = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not counters:
            # Replace [digits:digits] with [0:0]
            new_line = ""
            j = 0
            while j < len(line):
                if line[j] == "[":
                    # Look for closing bracket
                    k = j + 1
                    while k < len(line) and line[k] != "]":
                        k += 1
                    if k < len(line):
                        # It's a counter
                        new_line += "[0:0]"
                        j = k + 1
                        continue
                new_line += line[j]
                j += 1
            line = new_line
        if line.strip():
            formatted.append(line.strip())
        i += 1
    return formatted


def _extract_table_content(content, table):
    lines = content.splitlines()
    in_table = False
    result = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == "*" + table:
            in_table = True
            result.append(line)
        elif in_table:
            result.append(line)
            if line.strip() == "COMMIT":
                break
        i += 1
    return "\n".join(result)
