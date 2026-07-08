def main(ctx, params):
    # Normalize state mapping (Ansible's 'present'/'installed' etc. → internal states)
    def normalize_state(state):
        if state in ("present", "installed"):
            return "installed"
        if state in ("latest", "upgraded"):
            return "upgraded"
        if state in ("head",):
            return "head"
        if state in ("linked",):
            return "linked"
        if state in ("unlinked",):
            return "unlinked"
        if state in ("absent", "removed", "uninstalled"):
            return "absent"
        return state

    # Extract parameters
    names = params.get("name") or []
    if not isinstance(names, list):
        names = [names]
    path_list_str = params.get("path", "/usr/local/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin")
    path_list = path_list_str.split(":")
    state = normalize_state(params.get("state", "present"))
    update_homebrew = params.get("update_homebrew", False)
    upgrade_all = params.get("upgrade_all", False)
    install_opts = params.get("install_options") or []
    upgrade_opts = params.get("upgrade_options") or []

    # Build brew command path
    def find_brew(paths):
        for d in paths:
            brew_path = d + "/brew"
            if ctx.file_exists(brew_path):
                return brew_path
        return None

    brew_path = find_brew(path_list)
    if brew_path == None:
        fail("Unable to locate homebrew executable. Ensure Homebrew is installed and in the provided path.")

    # State tracking
    unchanged_pkgs = []
    changed_pkgs = []
    changed_count = 0
    unchanged_count = 0
    changed_flag = False
    message = ""

    # Helper: run brew command
    def run_brew(argv, mutates=False, ok_codes=[0]):
        full_argv = [brew_path] + argv
        return ctx.run(full_argv, mutates=mutates, ok_codes=ok_codes)

    # Check if package is installed using `brew info --json=v2`
    def package_is_installed(pkg):
        res = run_brew(["info", "--json=v2", pkg])
        if res.rc != 0:
            return False
        output = res.stdout
        # Very basic JSON parsing to detect installed state
        # Look for "formulae" or "casks" and check if first item has "installed"
        if "formulae" in output:
            if '"installed": true' in output:
                return True
        if "casks" in output:
            if '"installed": true' in output:
                return True
        return False

    def package_is_outdated(pkg):
        res = run_brew(["outdated", pkg], mutates=False, ok_codes=[0, 1])
        # rc 0 = outdated, rc 1 = up-to-date
        return res.rc == 0

    def package_is_head_installed(pkg):
        res = run_brew(["info", pkg], mutates=False, ok_codes=[0])
        if res.rc != 0:
            return False
        lines = res.stdout.splitlines()
        if len(lines) == 0:
            return False
        last_part = lines[0].strip().split(" ")[-1]
        return last_part == "HEAD"

    # --- Actions ---

    if update_homebrew:
        if ctx.check_mode:
            changed_flag = True
            message = "Homebrew would be updated."
            return {"changed": True, "msg": message}
        res = run_brew(["update"], mutates=True, ok_codes=[0])
        if res.rc != 0:
            fail("Failed to update Homebrew: " + res.stderr)
        changed_flag = True

    if upgrade_all:
        if ctx.check_mode:
            changed_flag = True
            message = "Homebrew packages would be upgraded."
            return {"changed": True, "msg": message}
        cmd = [brew_path, "upgrade"] + upgrade_opts
        res = ctx.run(cmd, mutates=True, ok_codes=[0])
        if res.rc != 0:
            fail("Failed to upgrade all packages: " + res.stderr)
        changed_flag = True

    # Process individual packages if provided
    if len(names) > 0:
        for pkg in names:
            if state == "installed":
                if package_is_installed(pkg):
                    unchanged_count += 1
                    unchanged_pkgs.append(pkg)
                    continue
                if ctx.check_mode:
                    changed_flag = True
                    continue
                head_opt = ["--HEAD"] if state == "head" else []
                opts = ["install"] + install_opts + [pkg] + head_opt
                opts = [opt for opt in opts if opt]
                res = run_brew(opts, mutates=True)
                if res.rc != 0:
                    fail("Failed to install " + pkg + ": " + res.stderr)
                if package_is_installed(pkg):
                    changed_count += 1
                    changed_pkgs.append(pkg)
                    changed_flag = True
                else:
                    fail("Package " + pkg + " not installed after install command.")
            elif state == "upgraded":
                if not package_is_installed(pkg):
                    # Treat as install if not installed
                    if ctx.check_mode:
                        changed_flag = True
                        continue
                    opts = ["install"] + install_opts + [pkg]
                    res = run_brew(opts, mutates=True)
                    if res.rc != 0:
                        fail("Failed to install " + pkg + ": " + res.stderr)
                    changed_count += 1
                    changed_pkgs.append(pkg)
                    changed_flag = True
                elif not package_is_outdated(pkg):
                    unchanged_count += 1
                    unchanged_pkgs.append(pkg)
                else:
                    if ctx.check_mode:
                        changed_flag = True
                        continue
                    opts = ["upgrade"] + install_opts + [pkg]
                    res = run_brew(opts, mutates=True)
                    if res.rc != 0:
                        fail("Failed to upgrade " + pkg + ": " + res.stderr)
                    if not package_is_installed(pkg) or package_is_outdated(pkg):
                        fail("Package " + pkg + " failed to upgrade.")
                    changed_count += 1
                    changed_pkgs.append(pkg)
                    changed_flag = True
            elif state == "absent":
                if not package_is_installed(pkg):
                    unchanged_count += 1
                    unchanged_pkgs.append(pkg)
                else:
                    if ctx.check_mode:
                        changed_flag = True
                        continue
                    res = run_brew(["uninstall", "--force"] + install_opts + [pkg], mutates=True)
                    if res.rc != 0:
                        fail("Failed to uninstall " + pkg + ": " + res.stderr)
                    if not package_is_installed(pkg):
                        changed_count += 1
                        changed_pkgs.append(pkg)
                        changed_flag = True
                    else:
                        fail("Package " + pkg + " still installed after uninstall.")
            elif state == "linked":
                if not package_is_installed(pkg):
                    fail("Package " + pkg + " is not installed, cannot link.")
                if ctx.check_mode:
                    changed_flag = True
                    continue
                res = run_brew(["link"] + install_opts + [pkg], mutates=True)
                if res.rc != 0:
                    fail("Failed to link " + pkg + ": " + res.stderr)
                changed_count += 1
                changed_pkgs.append(pkg)
                changed_flag = True
            elif state == "unlinked":
                if not package_is_installed(pkg):
                    fail("Package " + pkg + " is not installed, cannot unlink.")
                if ctx.check_mode:
                    changed_flag = True
                    continue
                res = run_brew(["unlink"] + install_opts + [pkg], mutates=True)
                if res.rc != 0:
                    fail("Failed to unlink " + pkg + ": " + res.stderr)
                changed_count += 1
                changed_pkgs.append(pkg)
                changed_flag = True
            else:
                fail("Unsupported state: " + state)

    # Final message
    if len(names) > 0:
        if changed_count == 0 and unchanged_count == 0:
            message = "No packages processed."
        else:
            message = "Changed: %d, Unchanged: %d" % (changed_count, unchanged_count)
    else:
        if not message:
            message = "No packages specified."

    return {
        "changed": changed_flag,
        "msg": message,
        "unchanged_pkgs": unchanged_pkgs,
        "changed_pkgs": changed_pkgs,
    }
