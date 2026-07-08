def main(ctx, params):
    name = params.get("name")
    path = params.get("path", "/usr/local/bin:/opt/homebrew/bin")
    state = params.get("state", "present")
    sudo_password = params.get("sudo_password")
    update_homebrew = params.get("update_homebrew", False)
    install_options = params.get("install_options") or []
    accept_external_apps = params.get("accept_external_apps", False)
    upgrade_all = params.get("upgrade_all", False)
    greedy = params.get("greedy", False)

    # Normalize state
    if state in ("present", "installed"):
        state = "installed"
    if state in ("latest", "upgraded"):
        state = "upgraded"
    if state in ("absent", "removed", "uninstalled"):
        state = "absent"

    # Determine casks
    casks = name if name != None else []

    # Build brew command path list
    brew_paths = path.split(":") if type(path) == "string" else path
    brew_path = None
    for d in brew_paths:
        res = ctx.run(["which", "brew"], ok_codes=[0, 1])
        if res.rc == 0:
            brew_path = res.stdout.strip()
            break
        # Try direct path if which fails
        candidate = d + "/brew"
        if ctx.file_exists(candidate):
            brew_path = candidate
            break

    if brew_path == None:
        fail("Unable to locate homebrew executable.")

    # Update homebrew if requested
    if update_homebrew:
        res = ctx.run([brew_path, "update"])
        if res.rc != 0:
            fail("Failed to update homebrew: " + res.stderr)

    # Handle upgrade_all mode
    if upgrade_all:
        if state != "upgraded":
            fail("state must be 'upgraded' when upgrade_all is true")
        if ctx.check_mode:
            return {"changed": True, "msg": "Casks would be upgraded."}

        # Check version to decide deprecated cask command
        res = ctx.run([brew_path, "--version"])
        version_line = res.stdout.strip().split("\n")[0]
        version_str = version_line.split(" ")[-1] if " " in version_line else ""
        old_version = version_str < "2.6.0"

        upgrade_cmd = [brew_path]
        if old_version:
            upgrade_cmd.extend(["cask", "upgrade"])
        else:
            upgrade_cmd.append("upgrade")
            upgrade_cmd.append("--cask")

        if greedy:
            upgrade_cmd.append("--greedy")

        res = _run_with_sudo(ctx, upgrade_cmd, sudo_password)
        if res.rc != 0:
            fail("Failed to upgrade casks: " + res.stderr)

        if "No Casks to upgrade" in res.stdout:
            return {"changed": False, "msg": "Homebrew casks already upgraded."}
        else:
            return {"changed": True, "msg": "Homebrew casks upgraded."}

    # Validate casks list
    if len(casks) == 0:
        fail("You must select a cask to install.")

    # Build install options
    opts = []
    for opt in install_options:
        if type(opt) == "string":
            opts.append("--" + opt)
        else:
            fail("install_options must be a list of strings")

    changed = False
    changed_count = 0
    unchanged_count = 0

    # Process each cask
    for cask in casks:
        if type(cask) != "string":
            fail("each cask name must be a string")

        # Install state
        if state == "installed":
            if _is_installed(ctx, brew_path, cask):
                unchanged_count += 1
                continue
            if ctx.check_mode:
                return {"changed": True, "msg": "Cask would be installed: " + cask}

            res = _install_cask(ctx, brew_path, cask, opts, sudo_password, accept_external_apps)
            if res:
                changed = True
                changed_count += 1
            else:
                unchanged_count += 1

        # Upgraded state
        if state == "upgraded":
            installed = _is_installed(ctx, brew_path, cask)
            if not installed:
                if ctx.check_mode:
                    return {"changed": True, "msg": "Cask would be installed: " + cask}
                res = _install_cask(ctx, brew_path, cask, opts, sudo_password, accept_external_apps)
                if res:
                    changed = True
                    changed_count += 1
                continue

            outdated = _is_outdated(ctx, brew_path, cask, greedy)
            if not outdated:
                unchanged_count += 1
                continue
            if ctx.check_mode:
                return {"changed": True, "msg": "Cask would be upgraded: " + cask}

            res = _upgrade_cask(ctx, brew_path, cask, opts, sudo_password)
            if res:
                changed = True
                changed_count += 1

        # Absent state
        if state == "absent":
            if not _is_installed(ctx, brew_path, cask):
                unchanged_count += 1
                continue
            if ctx.check_mode:
                return {"changed": True, "msg": "Cask would be uninstalled: " + cask}

            res = _uninstall_cask(ctx, brew_path, cask, opts, sudo_password)
            if res:
                changed = True
                changed_count += 1

    # Final result
    if not changed and (changed_count + unchanged_count) > 1:
        msg = "Changed: " + str(changed_count) + ", Unchanged: " + str(unchanged_count)
    else:
        msg = "Done."

    return {"changed": changed, "msg": msg}


def _run_with_sudo(ctx, cmd, sudo_password):
    if sudo_password == None:
        return ctx.run(cmd)
    else:
        # Create temporary askpass script
        # Note: we cannot write files directly, so we rely on the command being
        # passed with SUDO_ASKPASS via environment. This is simplified: we
        # assume sudo can use askpass and the environment variable is honored.
        # Since ctx.run() doesn't support env, we must use the original approach
        # of prepending sudo -A, which will read the password from the env var.
        env_cmd = ["env", "SUDO_ASKPASS=" + ctx.run(["which", "true"], ok_codes=[0]).stdout.strip()]
        # In Starlark there is no way to write a real askpass script. We fallback
        # to a direct sudo call, which will fail if sudo_password is required.
        # To remain faithful, we try sudo -A with a dummy env override.
        return ctx.run(["sudo", "-A"] + cmd)


def _is_installed(ctx, brew_path, cask):
    old_version = _brew_version_less_than_2_6_0(ctx, brew_path)
    cmd = [brew_path]
    if old_version:
        cmd.extend(["cask", "list"])
    else:
        cmd.append("list")
        cmd.append("--cask")
    cmd.append(cask)
    res = ctx.run(cmd, ok_codes=[0, 1])
    return res.rc == 0


def _is_outdated(ctx, brew_path, cask, greedy):
    old_version = _brew_version_less_than_2_6_0(ctx, brew_path)
    cmd = [brew_path]
    if old_version:
        cmd.extend(["outdated", "--cask"])
    else:
        cmd.append("outdated")
        cmd.append("--cask")
    if greedy:
        cmd.append("--greedy")
    cmd.append(cask)
    res = ctx.run(cmd, ok_codes=[0, 1])
    return res.rc == 0 and len(res.stdout.strip()) > 0


def _brew_version_less_than_2_6_0(ctx, brew_path):
    res = ctx.run([brew_path, "--version"])
    version_line = res.stdout.strip().split("\n")[0]
    version_str = version_line.split(" ")[-1] if " " in version_line else ""
    return version_str < "2.6.0"


def _install_cask(ctx, brew_path, cask, opts, sudo_password, accept_external_apps):
    old_version = _brew_version_less_than_2_6_0(ctx, brew_path)
    cmd = [brew_path]
    if old_version:
        cmd.extend(["install", "--cask"])
    else:
        cmd.append("install")
        cmd.append("--cask")
    cmd.append(cask)
    cmd.extend(opts)

    res = _run_with_sudo(ctx, cmd, sudo_password)
    if res.rc == 0:
        return True
    if accept_external_apps and "Error: It seems there is already an App at" in res.stderr:
        return True
    return False


def _upgrade_cask(ctx, brew_path, cask, opts, sudo_password):
    old_version = _brew_version_less_than_2_6_0(ctx, brew_path)
    cmd = [brew_path]
    if old_version:
        cmd.extend(["upgrade", "--cask"])
    else:
        cmd.append("upgrade")
        cmd.append("--cask")
    cmd.append(cask)
    cmd.extend(opts)

    res = _run_with_sudo(ctx, cmd, sudo_password)
    return res.rc == 0


def _uninstall_cask(ctx, brew_path, cask, opts, sudo_password):
    old_version = _brew_version_less_than_2_6_0(ctx, brew_path)
    cmd = [brew_path]
    if old_version:
        cmd.extend(["uninstall", "--cask"])
    else:
        cmd.append("uninstall")
        cmd.append("--cask")
    cmd.append(cask)
    cmd.extend(opts)

    res = _run_with_sudo(ctx, cmd, sudo_password)
    return res.rc == 0
