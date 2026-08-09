def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    executable = params.get("executable")
    prompts = params.get("prompts", [])

    # Normalize state
    if state in ("present", "installed"):
        state = "present"
    elif state in ("absent", "removed"):
        state = "absent"
    elif state not in ("present", "latest"):
        fail("unsupported state: " + state)

    # Parse packages list
    pkgs = name.split(",")

    # Build pear command path
    if executable != None and ctx.file_exists(executable):
        pear_cmd = [executable]
    else:
        pear_cmd = ["pear"]

    def run_pear(args, stdin_data=None):
        if stdin_data != None:
            res = ctx.run(pear_cmd + args, stdin=stdin_data, mutates=True)
        else:
            res = ctx.run(pear_cmd + args, mutates=True)
        return res

    def query_package(pkg_name):
        # Check if installed (local info)
        res_local = run_pear(["info", pkg_name])
        if res_local.rc != 0:
            return False, False

        # Get remote info for version comparison
        res_remote = run_pear(["remote-info", pkg_name])
        if res_remote.rc != 0:
            return False, False

        # Extract installed version from remote-info output
        lines = res_remote.stdout.split("\n")
        local_version = None
        remote_version = None
        for line in lines:
            if line.startswith("Installed"):
                parts = line.split()
                if len(parts) >= 2 and parts[-1].strip() != "-":
                    local_version = parts[-1].strip()
            elif line.startswith("Latest"):
                parts = line.split()
                if len(parts) >= 2:
                    remote_version = parts[-1].strip()
        return local_version != None, local_version == remote_version

    # Handle check_mode
    if ctx.check_mode:
        would_change = []
        for pkg in pkgs:
            installed, updated = query_package(pkg)
            if state == "present" and not installed:
                would_change.append(pkg)
            elif state == "latest" and (not installed or not updated):
                would_change.append(pkg)
            elif state == "absent" and installed:
                would_change.append(pkg)
        if len(would_change) > 0:
            return {"changed": True, "msg": str(len(would_change)) + " package(s) would be " + state}
        else:
            return {"changed": False, "msg": "package(s) already " + state}

    # Handle changes
    changed = False

    if state in ("present", "latest"):
        command = "upgrade" if state == "latest" else "install"
        # Process prompts
        prompt_list = []
        for item in prompts:
            if type(item) == "dict":
                key = list(item.keys())[0]
                answer = str(item[key]) + "\n"
                prompt_list.append((key, answer))
            elif item == None:
                prompt_list.append((None, "\n"))
            else:
                prompt_list.append((str(item), "\n"))

        # Warn if prompt count mismatch
        if len(prompts) > 0 and len(prompts) != len(pkgs):
            if len(prompts) > len(pkgs):
                diff = len(prompts) - len(pkgs)
                msg = str(len(pkgs)) + " packages to install but " + str(len(prompts)) + " prompts to expect. " + str(diff) + " prompts will be ignored"
            else:
                diff = len(pkgs) - len(prompts)
                msg = str(len(pkgs)) + " packages to install but only " + str(len(prompts)) + " prompts to expect. " + str(diff) + " packages won't be expected to have a prompt"
            ctx.warn(msg)

        install_count = 0
        for i, pkg in enumerate(pkgs):
            installed, updated = query_package(pkg)
            if installed and (state == "present" or (state == "latest" and updated)):
                continue

            stdin_data = None
            if i < len(prompt_list) and prompt_list[i][0] != None:
                stdin_data = prompt_list[i][1]
            res = run_pear([command, pkg], stdin_data=stdin_data)
            if res.rc != 0:
                fail("failed to " + command + " " + pkg + ": " + res.stderr)
            install_count += 1
            changed = True

        if install_count > 0:
            return {"changed": changed, "msg": "installed " + str(install_count) + " package(s)"}
        else:
            return {"changed": False, "msg": "package(s) already installed"}

    elif state == "absent":
        remove_count = 0
        for pkg in pkgs:
            installed, _ = query_package(pkg)
            if not installed:
                continue
            res = run_pear(["uninstall", pkg])
            if res.rc != 0:
                fail("failed to remove " + pkg + ": " + res.stderr)
            remove_count += 1
            changed = True

        if remove_count > 0:
            return {"changed": changed, "msg": "removed " + str(remove_count) + " package(s)"}
        else:
            return {"changed": False, "msg": "package(s) already absent"}

    fail("unhandled state: " + state)
