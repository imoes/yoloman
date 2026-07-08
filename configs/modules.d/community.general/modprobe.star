def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    mod_params = params.get("params", "")
    persistent = params.get("persistent", "disabled")

    # Validate state and persistent combinations
    if state not in ("present", "absent"):
        fail("unsupported state: " + state)
    if persistent not in ("disabled", "present", "absent"):
        fail("unsupported persistent value: " + persistent)

    # Check if systemd is available (prerequisite for persistent mode)
    res = ctx.run(["systemctl", "is-system-running"], mutates=False)
    systemd_available = res.rc == 0 or "running" in res.stdout.lower() or "degraded" in res.stdout.lower()
    if persistent != "disabled" and not systemd_available:
        fail("systemd must be available when persistent is set to " + persistent)

    # Helper to check if module is currently loaded
    def module_loaded():
        # Check /proc/modules
        content = ctx.file_read("/proc/modules") if ctx.file_exists("/proc/modules") else ""
        # Normalize hyphens to underscores in module name for matching
        normalized_name = name.replace("-", "_") + " "
        for line in content.split("\n"):
            if line.startswith(normalized_name):
                return True
        # Check built-in modules
        rel_ver = ctx.facts().get("distribution_version", "")
        # Try to get kernel release from uname if available
        uname_res = ctx.run(["uname", "-r"], mutates=False)
        if uname_res.rc == 0 and uname_res.stdout.strip():
            rel_ver = uname_res.stdout.strip()
        builtin_path = "/lib/modules/" + rel_ver + "/modules.builtin"
        if ctx.file_exists(builtin_path):
            content = ctx.file_read(builtin_path)
            module_file = "/" + name + ".ko"
            for line in content.split("\n"):
                if line.rstrip().endswith(module_file):
                    return True
        return False

    # Helper to get module files in /etc/modules-load.d/
    def get_modules_files():
        files = []
        if ctx.file_exists("/etc/modules-load.d"):
            dir_res = ctx.run(["ls", "-1", "/etc/modules-load.d"], mutates=False)
            if dir_res.rc == 0:
                for f in dir_res.stdout.split("\n"):
                    if f.strip():
                        path = "/etc/modules-load.d/" + f.strip()
                        if ctx.file_exists(path):
                            files.append(path)
        return files

    # Helper to get modprobe files in /etc/modprobe.d/
    def get_modprobe_files():
        files = []
        if ctx.file_exists("/etc/modprobe.d"):
            dir_res = ctx.run(["ls", "-1", "/etc/modprobe.d"], mutates=False)
            if dir_res.rc == 0:
                for f in dir_res.stdout.split("\n"):
                    if f.strip():
                        path = "/etc/modprobe.d/" + f.strip()
                        if ctx.file_exists(path):
                            files.append(path)
        return files

    # Check persistent state helpers
    def module_is_loaded_persistently():
        pattern = "^ *" + name + r" *(?:[#;].*)?\n?\Z"
        for f in get_modules_files():
            content = ctx.file_read(f)
            for line in content.split("\n"):
                # Simple pattern match using startswith and strip
                stripped = line.strip()
                # Check if line starts with module name (possibly commented)
                if stripped.startswith("#"):
                    stripped = stripped[1:].strip()
                if stripped == name:
                    return True
        return False

    def get_permanent_params():
        params_set = set()
        pattern_prefix = "options " + name + " "
        for f in get_modprobe_files():
            content = ctx.file_read(f)
            for line in content.split("\n"):
                stripped = line.strip()
                # Allow commented lines to be checked
                if stripped.startswith("#"):
                    stripped = stripped[1:].strip()
                if stripped.startswith(pattern_prefix):
                    # Extract param=value part
                    param_part = stripped[len(pattern_prefix):].strip()
                    # Split by spaces and collect param=value
                    for p in param_part.split():
                        if "=" in p:
                            params_set.add(p)
        return params_set

    def params_is_set():
        desired_params = set()
        if mod_params:
            for p in mod_params.split():
                if p and "=" in p:
                    desired_params.add(p)
        return desired_params == get_permanent_params()

    # Current state
    currently_loaded = module_loaded()
    currently_persistent = module_is_loaded_persistently()
    current_params_set = params_is_set()

    # Perform actions
    changed = False
    msg = ""

    # Load/unload module (non-persistent)
    if state == "present" and not currently_loaded:
        if ctx.check_mode:
            return {"changed": True, "msg": "would load module " + name}
        # Load module
        args = ["modprobe", name]
        if mod_params:
            args.extend(mod_params.split())
        res = ctx.run(args, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would load module " + name}
        if res.rc != 0:
            fail("failed to load module " + name + ": " + res.stderr)
        changed = True
        msg = "loaded module " + name
    elif state == "absent" and currently_loaded:
        if ctx.check_mode:
            return {"changed": True, "msg": "would unload module " + name}
        res = ctx.run(["modprobe", "-r", name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would unload module " + name}
        if res.rc != 0:
            fail("failed to unload module " + name + ": " + res.stderr)
        changed = True
        msg = "unloaded module " + name

    # Handle persistent state
    if persistent == "present":
        # Ensure module is loaded persistently and params are set
        if not currently_persistent:
            if ctx.check_mode:
                return {"changed": True, "msg": "would make module " + name + " persistent"}
            # Create module file
            content = name + "\n"
            file_path = "/etc/modules-load.d/" + name + ".conf"
            ctx.file_write(file_path, content, "0644")
            changed = True
        if not current_params_set:
            if ctx.check_mode:
                return {"changed": True, "msg": "would set module parameters for " + name}
            # Disable old params by commenting them out
            pattern_prefix = "options " + name + " "
            for f in get_modprobe_files():
                content = ctx.file_read(f)
                lines = content.split("\n")
                new_lines = []
                found = False
                for line in lines:
                    stripped = line.strip()
                    if stripped.startswith("#"):
                        uncomm = stripped[1:]
                    else:
                        uncomm = stripped
                    if uncomm.startswith(pattern_prefix):
                        # Comment it out
                        new_lines.append("#" + line)
                        found = True
                    else:
                        new_lines.append(line)
                if found:
                    ctx.file_write(f, "\n".join(new_lines), None)
            # Create new param file
            file_path = "/etc/modprobe.d/" + name + ".conf"
            param_content = ""
            if mod_params:
                for p in mod_params.split():
                    if p and "=" in p:
                        param_content += "options " + name + " " + p + "\n"
            else:
                param_content = ""
            ctx.file_write(file_path, param_content, "0644")
            changed = True
        if changed and not msg:
            msg = "made module " + name + " persistent"
    elif persistent == "absent":
        # Ensure module is not loaded persistently and params are unset
        if currently_persistent or (get_permanent_params()):
            if ctx.check_mode:
                return {"changed": True, "msg": "would disable persistent module " + name}
            # Comment out in modules-load.d files
            for f in get_modules_files():
                content = ctx.file_read(f)
                lines = content.split("\n")
                new_lines = []
                found = False
                for line in lines:
                    stripped = line.strip()
                    # Skip already commented
                    if stripped.startswith("#"):
                        if stripped[1:].strip() == name:
                            new_lines.append(line)
                            found = True
                        else:
                            new_lines.append(line)
                    elif stripped == name:
                        new_lines.append("#" + line)
                        found = True
                    else:
                        new_lines.append(line)
                if found:
                    ctx.file_write(f, "\n".join(new_lines), None)
            # Comment out params in modprobe.d files
            pattern_prefix = "options " + name + " "
            for f in get_modprobe_files():
                content = ctx.file_read(f)
                lines = content.split("\n")
                new_lines = []
                found = False
                for line in lines:
                    stripped = line.strip()
                    if stripped.startswith(pattern_prefix) or (stripped.startswith("#") and stripped[1:].strip().startswith(pattern_prefix)):
                        new_lines.append("#" + line)
                        found = True
                    else:
                        new_lines.append(line)
                if found:
                    ctx.file_write(f, "\n".join(new_lines), None)
            changed = True
            if not msg:
                msg = "disabled persistent module " + name

    if not changed:
        msg = "module " + name + " already in desired state"

    return {"changed": changed, "msg": msg}
