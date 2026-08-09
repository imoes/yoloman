def main(ctx, params):
    # Parse parameters
    names = params["name"]
    state = params.get("state", "present")
    force = params.get("force", "")
    update_cache = params.get("update_cache", False)
    executable = params.get("executable", "opkg")

    # Validate state
    if state not in ("present", "absent", "installed", "removed"):
        fail("unsupported state: " + state)

    # Map state aliases
    if state == "installed":
        state = "present"
    elif state == "removed":
        state = "absent"

    # Normalize force (empty string means no force flag)
    force_val = None if force == "" else force

    # Build base command
    opkg_cmd = [executable]

    # Update cache if requested
    if update_cache:
        res = ctx.run(opkg_cmd + ["update"], mutates=False)
        if res.rc != 0:
            fail("failed to update package database: " + res.stderr)

    # Determine desired packages and current state
    pkg_to_install = []
    pkg_to_remove = []

    for pkg in names:
        # Split name and version for NAME=VERSION syntax
        parts = pkg.split("=", 1)
        name = parts[0]
        version = parts[1] if len(parts) == 2 else None

        # Check current installation status
        res = ctx.run(opkg_cmd + ["list-installed"], mutates=False)
        installed = False
        version_ok = False

        for line in res.stdout.splitlines():
            if line.startswith(name + " - "):
                installed = True
                if version == None:
                    version_ok = True
                else:
                    # Check version match (opkg format: "name - version")
                    current_version = line[len(name) + 3:].split()[0] if " " in line[len(name) + 3:] else ""
                    version_ok = current_version == version
                break

        if state == "present":
            # Install if not installed, or version mismatch, or force reinstall
            if not installed or (version != None and not version_ok) or force_val == "reinstall":
                pkg_to_install.append(pkg)
        else:  # absent
            # Remove if installed (ignore version for removal)
            if installed:
                pkg_to_remove.append(name)

    # Compute expected changes
    changed = len(pkg_to_install) > 0 or len(pkg_to_remove) > 0

    # Check mode
    if ctx.check_mode:
        if changed:
            msg = ""
            if len(pkg_to_install) > 0:
                msg += "would install " + ", ".join(pkg_to_install)
            if len(pkg_to_remove) > 0:
                if msg:
                    msg += "; "
                msg += "would remove " + ", ".join(pkg_to_remove)
            return {"changed": True, "msg": msg}
        else:
            if state == "present":
                return {"changed": False, "msg": "package(s) already present"}
            else:
                return {"changed": False, "msg": "package(s) already absent"}

    # Perform installation
    install_count = 0
    remove_count = 0

    if len(pkg_to_install) > 0:
        cmd = opkg_cmd + ["install"]
        if force_val:
            cmd += ["--force-" + force_val]
        cmd += pkg_to_install

        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("failed to install package(s): " + res.stderr)
        install_count = len(pkg_to_install)

    # Perform removal
    if len(pkg_to_remove) > 0:
        cmd = opkg_cmd + ["remove"]
        if force_val:
            cmd += ["--force-" + force_val]
        cmd += pkg_to_remove

        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("failed to remove package(s): " + res.stderr)
        remove_count = len(pkg_to_remove)

    # Prepare message
    if install_count > 0 and remove_count > 0:
        msg = "installed %d package(s) and removed %d package(s)" % (install_count, remove_count)
    elif install_count > 0:
        msg = "installed %d package(s)" % install_count
    elif remove_count > 0:
        msg = "removed %d package(s)" % remove_count
    elif state == "present":
        msg = "package(s) already present"
    else:
        msg = "package(s) already absent"

    changed = install_count > 0 or remove_count > 0
    return {"changed": changed, "msg": msg}
