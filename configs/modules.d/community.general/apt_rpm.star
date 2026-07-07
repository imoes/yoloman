def main(ctx, params):
    # Constants
    APT_PATH = "/usr/bin/apt-get"
    RPM_PATH = "/usr/bin/rpm"
    UPDATE_KERNEL_PATH = "/usr/sbin/update-kernel"

    # Check required binaries exist
    if not ctx.file_exists(APT_PATH) or not ctx.file_exists(RPM_PATH):
        fail("cannot find /usr/bin/apt-get and/or /usr/bin/rpm")

    # Parameters
    state = params.get("state", "present")
    update_cache = params.get("update_cache", False)
    clean = params.get("clean", False)
    dist_upgrade = params.get("dist_upgrade", False)
    update_kernel = params.get("update_kernel", False)
    packages = params.get("package")  # list or None

    changed = False
    msg_parts = []

    # Handle update_cache (always runs, mutates system)
    if update_cache:
        res = ctx.run([APT_PATH, "update"], mutates=True)
        if res.skipped:
            msg_parts.append("would update package cache")
        elif res.rc != 0:
            fail("apt-get update failed: " + res.stderr)
        else:
            changed = True
            msg_parts.append("package cache updated")

    # Handle clean (mutates system)
    if clean:
        cache_dir = "/var/cache/apt/archives"

        # Probe current cache size
        def get_total_size(path):
            total = 0
            res = ctx.run(["find", path, "-type", "f"], mutates=False)
            for entry in res.stdout.splitlines():
                entry = entry.strip()
                if entry != "":
                    stat = ctx.stat(entry)
                    if stat != None and stat.get("exists"):
                        total += stat.get("size", 0)
            return total

        old_size = get_total_size(cache_dir)

        res = ctx.run([APT_PATH, "clean"], mutates=True)
        if res.skipped:
            msg_parts.append("would run apt-get clean")
        elif res.rc != 0:
            fail("apt-get clean failed: " + res.stderr)
        else:
            new_size = get_total_size(cache_dir)
            if old_size != new_size:
                changed = True
            msg_parts.append("apt-get clean executed")

    # Handle dist_upgrade (mutates system)
    if dist_upgrade:
        res = ctx.run([APT_PATH, "-y", "dist-upgrade"], mutates=True)
        if res.skipped:
            msg_parts.append("would run apt-get dist-upgrade")
        elif res.rc != 0:
            fail("apt-get dist-upgrade failed: " + res.stderr)
        else:
            # Detect change by checking if "0 upgraded, 0 newly installed" is missing
            if "\n0 upgraded, 0 newly installed" not in res.stdout:
                changed = True
            msg_parts.append("apt-get dist-upgrade executed")

    # Handle update_kernel (mutates system)
    if update_kernel:
        res = ctx.run([UPDATE_KERNEL_PATH, "-y"], mutates=True)
        if res.skipped:
            msg_parts.append("would run update-kernel")
        elif res.rc != 0:
            fail("update-kernel failed: " + res.stderr)
        else:
            # Detect change by checking if "Try to install new kernel " is missing
            if "\nTry to install new kernel " not in res.stdout:
                changed = True
            msg_parts.append("update-kernel executed")

    # Helper functions
    def query_package(name):
        # rpm -q returns 0 if installed, non-zero otherwise
        res = ctx.run([RPM_PATH, "-q", name], mutates=False)
        return res.rc == 0

    def install_or_remove_packages(pkg_list, desired_state):
        local_changed = False
        if pkg_list == None:
            return local_changed, "Empty package list"

        to_process = []
        for pkg in pkg_list:
            is_installed = query_package(pkg)
            if desired_state in ["installed", "present"]:
                if not is_installed:
                    to_process.append(pkg)
            elif desired_state in ["absent", "removed"]:
                if is_installed:
                    to_process.append(pkg)

        if len(to_process) == 0:
            return False, "package(s) already in desired state"

        # Prepare command args
        if desired_state in ["installed", "present"]:
            cmd = [APT_PATH, "-y", "install"] + to_process
            success_msg = "package(s) installed"
        else:
            cmd = [APT_PATH, "-y", "remove"] + to_process
            success_msg = "package(s) removed"

        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return True, "would " + success_msg

        if res.rc != 0:
            fail("apt-get " + ("install" if desired_state in ["installed", "present"] else "remove") + " failed: " + res.stderr)

        # Verify result: check if all requested packages now match desired state
        all_ok = True
        for pkg in to_process:
            is_installed = query_package(pkg)
            if desired_state in ["installed", "present"]:
                if not is_installed:
                    all_ok = False
            elif desired_state in ["absent", "removed"]:
                if is_installed:
                    all_ok = False

        if not all_ok:
            fail("package verification failed for " + str(to_process))

        return True, success_msg

    # Handle package state
    if state in ["installed", "present"]:
        c, m = install_or_remove_packages(packages, "installed")
        changed = changed or c
        msg_parts.append(m)

    if state in ["absent", "removed"]:
        c, m = install_or_remove_packages(packages, "absent")
        changed = changed or c
        msg_parts.append(m)

    # Final message
    full_msg = "; ".join(msg_parts) if msg_parts else "no operations performed"

    return {"changed": changed, "msg": full_msg}
