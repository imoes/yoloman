def main(ctx, params):
    executable = params.get("executable", "pacman")
    extra_args = params.get("extra_args", "")
    force = params.get("force", False)
    names = params.get("name") or []
    reason = params.get("reason")
    reason_for = params.get("reason_for", "new")
    remove_nosave = params.get("remove_nosave", False)
    state = params.get("state", "present")
    update_cache = params.get("update_cache", False)
    update_cache_extra_args = params.get("update_cache_extra_args", "")
    upgrade = params.get("upgrade", False)
    upgrade_extra_args = params.get("upgrade_extra_args", "")

    # Normalize state aliases
    if state == "installed":
        target_state = "present"
    elif state == "removed":
        target_state = "absent"
    else:
        target_state = state

    # Validate mutually exclusive options
    if names and upgrade:
        fail("name and upgrade are mutually exclusive")

    if not names and not update_cache and not upgrade:
        fail("One of name, update_cache, or upgrade is required")

    # Helper to run pacman commands
    def run_pacman(argv, mutates=False, ok_codes=[0]):
        full_argv = [executable] + argv
        return ctx.run(full_argv, mutates=mutates, ok_codes=ok_codes)

    # Helper to build extra args list
    def build_extra_args(extra_str):
        return extra_str.split() if extra_str else []

    # Update cache
    cache_updated = False
    if update_cache:
        if ctx.check_mode:
            cache_updated = True
            if not (names or upgrade):
                return {"changed": True, "msg": "Would have updated the package database", "cache_updated": True}
        else:
            cmd = ["--sync", "--refresh"]
            cmd += build_extra_args(update_cache_extra_args)
            if force:
                cmd += ["--refresh"]
            res = run_pacman(cmd, mutates=True)
            if res.rc != 0:
                fail("Could not update package database: " + res.stderr)
            cache_updated = True
            # If cache_updated flag is required in return
            # For simplicity, we set it to True when update_cache is used

    if not names and not upgrade:
        if cache_updated:
            return {"changed": True, "msg": "Package database updated", "cache_updated": True}
        return {"changed": False, "msg": "Nothing to do"}

    # Build inventory of installed/available packages
    # Query installed packages
    res = run_pacman(["--query"])
    if res.rc != 0:
        fail("Failed to list installed packages: " + res.stderr)
    installed_pkgs = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2:
            installed_pkgs[parts[0]] = parts[1]

    # Query available packages (sync database)
    res = run_pacman(["--sync", "--list"])
    if res.rc != 0:
        fail("Failed to list available packages: " + res.stderr)
    available_pkgs = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3:
            available_pkgs[parts[1]] = parts[2]

    # Query upgradable packages
    res = run_pacman(["--query", "--upgrades"], ok_codes=[0, 1])
    upgradable_pkgs = {}
    if res.rc == 0:
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if "Avoid running" in line:
                continue
            # Format: pkg current -> latest
            parts = line.split()
            if len(parts) == 4 and parts[2] == "->":
                pkg = parts[0]
                current = parts[1]
                latest = parts[3]
                if "[ignored]" not in line:
                    upgradable_pkgs[pkg] = {"current": current, "latest": latest}

    # Query package reasons
    res = run_pacman(["--query", "--explicit"])
    pkg_reasons = {}
    if res.rc == 0:
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if parts:
                pkg_reasons[parts[0]] = "explicit"

    res = run_pacman(["--query", "--deps"])
    if res.rc == 0:
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if parts and parts[0] not in pkg_reasons:
                pkg_reasons[parts[0]] = "dependency"

    # Process package list
    pkg_list = []
    for pkg in names:
        if not pkg:
            continue
        # Check if it's a group
        # We don't fully implement groups; just pass through for now
        pkg_list.append(pkg)

    # Handle upgrade
    if upgrade:
        if not upgradable_pkgs:
            if ctx.check_mode:
                return {"changed": False, "msg": "Nothing to upgrade"}
            else:
                return {"changed": False, "msg": "Nothing to upgrade"}
        if ctx.check_mode:
            diff_before = "\n".join(sorted([k + "-" + v["current"] for k, v in upgradable_pkgs.items()])) + "\n"
            diff_after = "\n".join(sorted([k + "-" + v["latest"] for k, v in upgradable_pkgs.items()])) + "\n"
            return {
                "changed": True,
                "msg": str(len(upgradable_pkgs)) + " packages would be upgraded",
                "diff": {"before": diff_before, "after": diff_after},
                "packages": sorted(upgradable_pkgs.keys())
            }

        cmd = ["--sync", "--sysupgrade", "--quiet", "--noconfirm"]
        cmd += build_extra_args(upgrade_extra_args)
        res = run_pacman(cmd, mutates=True)
        if res.rc != 0:
            fail("Could not upgrade system: " + res.stderr)
        return {
            "changed": True,
            "msg": "System upgraded",
            "packages": sorted(upgradable_pkgs.keys())
        }

    # Handle package operations (install/remove)
    pkgs_to_operate = []
    if target_state == "absent":
        # Remove packages: only operate on installed ones
        for pkg in pkg_list:
            if pkg in installed_pkgs:
                pkgs_to_operate.append(pkg)
    else:
        # Install or latest: determine which packages need installing/updating
        for pkg in pkg_list:
            install_needed = False
            if pkg not in installed_pkgs:
                install_needed = True
            elif target_state == "latest" and pkg in upgradable_pkgs:
                install_needed = True
            if install_needed:
                pkgs_to_operate.append(pkg)

    # Check if anything to do
    if not pkgs_to_operate and not reason:
        if ctx.check_mode:
            return {"changed": False, "msg": "Package(s) already in desired state"}
        else:
            return {"changed": False, "msg": "Package(s) already in desired state"}

    if ctx.check_mode:
        if pkgs_to_operate:
            return {
                "changed": True,
                "msg": "Would have " + ("removed" if target_state == "absent" else "installed") + " " + str(len(pkgs_to_operate)) + " package(s)",
                "packages": pkgs_to_operate
            }
        else:
            return {
                "changed": True,
                "msg": "Would have changed package reason(s)",
                "packages": pkgs_to_operate
            }

    # Perform operations
    packages_changed = []

    if target_state == "absent":
        # Remove packages
        cmd = ["--remove", "--noconfirm", "--noprogressbar"]
        cmd += build_extra_args(extra_args)
        if force:
            cmd += ["--nodeps", "--nodeps"]
        cmd += pkgs_to_operate
        res = run_pacman(cmd, mutates=True)
        if res.rc != 0:
            fail("Failed to remove package(s): " + res.stderr)
        packages_changed = pkgs_to_operate
    else:
        # Install packages
        cmd = ["--sync", "--noconfirm", "--noprogressbar", "--needed"]
        cmd += build_extra_args(extra_args)
        cmd += pkgs_to_operate
        res = run_pacman(cmd, mutates=True)
        if res.rc != 0:
            fail("Failed to install package(s): " + res.stderr)
        packages_changed = pkgs_to_operate

    # Handle reason changes (only for new installs, per reason_for logic)
    if reason:
        # Only change reason for packages that were newly installed or all packages if reason_for is "all"
        reason_pkgs = pkgs_to_operate if reason_for == "new" else pkgs_to_operate + [p for p in pkg_list if p in installed_pkgs]
        if reason_pkgs:
            cmd = [executable, "--database"]
            if reason == "dependency":
                cmd.append("--asdeps")
            else:
                cmd.append("--asexplicit")
            cmd += reason_pkgs
            res = run_pacman(cmd, mutates=True)
            # Note: reason changes might not affect the change status if packages were already installed

    return {
        "changed": True,
        "msg": "Package operation completed",
        "packages": packages_changed
    }
