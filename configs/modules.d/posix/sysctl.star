def main(ctx, params):
    name = params["name"]
    value = params.get("value")
    state = params.get("state", "present")
    ignoreerrors = params.get("ignoreerrors", False)
    reload_flag = params.get("reload", True)
    sysctl_file = params.get("sysctl_file", "/etc/sysctl.conf")
    sysctl_set = params.get("sysctl_set", False)

    # Basic validation
    if state == "present" and value == None:
        fail("value is required when state is present")
    if not name:
        fail("name cannot be blank")

    # Get platform info
    facts = ctx.facts()
    distribution = facts.get("distribution", "").lower()

    # Normalize value
    def _normalize_value(v):
        if v == None:
            return ""
        if isinstance(v, bool):
            return "1" if v else "0"
        v_str = str(v).strip()
        if v_str.lower() in ("true", "yes", "on", "1"):
            return "1"
        if v_str.lower() in ("false", "no", "off", "0"):
            return "0"
        return v_str

    normalized_value = _normalize_value(value)

    # Helper: get sysctl binary path
    def get_sysctl_bin():
        res = ctx.run(["which", "sysctl"])
        if res.rc != 0:
            fail("sysctl binary not found")
        return res.stdout.strip()

    sysctl_bin = get_sysctl_bin()

    # Helper: get current kernel value
    def get_proc_value(key):
        if distribution == "openbsd":
            res = ctx.run([sysctl_bin, "-n", key])
        else:
            res = ctx.run([sysctl_bin, "-e", "-n", key])
        if res.rc != 0:
            return None
        return res.stdout.strip()

    proc_value = get_proc_value(name)

    # Helper: set sysctl value via -w
    def set_proc_value(key, val):
        # Quote if contains spaces
        if " " in val:
            val = '"' + val + '"'
        # Build command
        if distribution == "openbsd":
            cmd = [sysctl_bin, key + "=" + val]
        elif distribution == "freebsd":
            ignore = "-i" if ignoreerrors else ""
            if ignore:
                cmd = [sysctl_bin, ignore, key + "=" + val]
            else:
                cmd = [sysctl_bin, key + "=" + val]
        else:
            ignore = "-e" if ignoreerrors else ""
            if ignore:
                cmd = [sysctl_bin, ignore, "-w", key + "=" + val]
            else:
                cmd = [sysctl_bin, "-w", key + "=" + val]
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("setting " + key + " failed")
        return True

    # Helper: read sysctl file
    def read_sysctl_file(path):
        lines = []
        file_values = {}
        if ctx.file_exists(path):
            content = ctx.file_read(path)
            lines = content.splitlines()
            for line in lines:
                stripped = line.strip()
                if not stripped or stripped.startswith(("#", ";")) or "=" not in stripped:
                    continue
                parts = stripped.split("=", 1)
                if len(parts) == 2:
                    k = parts[0].strip()
                    v = parts[1].strip()
                    file_values[k] = v
        return lines, file_values

    file_lines, file_values = read_sysctl_file(sysctl_file)

    # Fix lines for new state
    def build_fixed_lines(lines, k, v, target_state):
        fixed = []
        keys_seen = set()
        for line in lines:
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", ";")) or "=" not in stripped:
                fixed.append(line)
                continue
            parts = stripped.split("=", 1)
            if len(parts) != 2:
                fixed.append(line)
                continue
            curr_k = parts[0].strip()
            curr_v = parts[1].strip()
            if curr_k not in keys_seen:
                keys_seen.add(curr_k)
                if curr_k == k:
                    if target_state == "present":
                        fixed.append(curr_k + "=" + v)
                    # else: omit line (absent)
                else:
                    fixed.append(curr_k + "=" + curr_v)
        if k not in keys_seen and target_state == "present":
            fixed.append(k + "=" + v)
        return fixed

    fixed_lines = build_fixed_lines(file_lines, name, normalized_value, state)

    # Determine changes needed
    file_value = file_values.get(name)
    changed = False
    write_file = False
    set_proc = False

    if state == "present":
        if file_value == None:
            changed = True
            write_file = True
        elif file_value != normalized_value:
            changed = True
            write_file = True
        elif reload_flag and (proc_value == None or proc_value != normalized_value):
            changed = True
    elif state == "absent":
        if file_value == None:
            changed = False
        else:
            changed = True
            write_file = True

    if sysctl_set and state == "present":
        if proc_value == None or proc_value != normalized_value:
            changed = True
            set_proc = True

    # Apply changes
    if ctx.check_mode:
        return {"changed": changed, "msg": "would update sysctl if needed"}

    # Set proc value if needed
    if set_proc:
        set_proc_value(name, normalized_value)

    # Write sysctl file if needed
    if write_file:
        content = "\n".join(fixed_lines)
        if fixed_lines:
            content = content + "\n"
        ctx.file_write(sysctl_file, content)

    # Reload if needed
    if changed and reload_flag:
        if distribution == "freebsd":
            res = ctx.run(["/etc/rc.d/sysctl", "reload"], mutates=True)
            if res.rc != 0:
                fail("Failed to reload sysctl on FreeBSD")
        elif distribution == "openbsd":
            # Set all keys individually
            for k, v in file_values.items():
                if k == name:
                    continue
                set_proc_value(k, v)
            if state == "present":
                set_proc_value(name, normalized_value)
        else:
            # Generic Linux: sysctl -p
            cmd = [sysctl_bin, "-p", sysctl_file]
            if ignoreerrors:
                cmd.insert(1, "-e")
            res = ctx.run(cmd, mutates=True)
            if res.rc != 0:
                fail("Failed to reload sysctl")

    return {"changed": changed, "msg": "sysctl updated"}
