def main(ctx, params):
    backend = params["backend"]
    image = params["image"]
    name = params["name"]
    rootfs = params.get("rootfs")
    mode = params.get("mode")
    state = params.get("state", "latest")
    values = params.get("values", [])

    # Validate mode for values option
    if values and mode == None:
        ctx.fail("values is supported only with user or system mode")

    # Check atomic availability
    atomic_bin_res = ctx.run(["which", "atomic"])
    if atomic_bin_res.rc != 0:
        ctx.fail("atomic command not found")

    atomic_bin = atomic_bin_res.stdout.strip()

    # Build values arguments list
    values_list = []
    for v in values:
        values_list.append("--set=" + v)

    # Query container status
    filter_args = [
        atomic_bin, "containers", "list", "--no-trunc", "-n", "--all",
        "-f", "backend=" + backend, "-f", "container=" + name
    ]
    list_res = ctx.run(filter_args, mutates=False)
    if list_res.rc != 0:
        ctx.fail("failed to list containers: " + list_res.stderr)

    present = name in list_res.stdout

    # State logic
    if state == "present" and present:
        return {"changed": False, "msg": list_res.stdout}

    if state in ["latest", "present"] and not present:
        # Install new container
        install_args = [atomic_bin, "install"]
        install_args += ["--storage=" + backend]
        install_args += ["--name=" + name]
        if mode == "system":
            install_args += ["--system"]
        elif mode == "user":
            install_args += ["--user"]
        if rootfs:
            install_args += ["--rootfs=" + rootfs]
        install_args += values_list
        install_args += [image]

        if ctx.check_mode:
            return {"changed": True, "msg": "would install container " + name}

        install_res = ctx.run(install_args, mutates=True)
        if install_res.rc != 0:
            ctx.fail("failed to install container: " + install_res.stderr)
        changed = "Extracting" in install_res.stdout or "Copying blob" in install_res.stdout
        return {"changed": changed, "msg": install_res.stdout}

    if state == "latest" and present:
        # Update existing container
        update_args = [atomic_bin, "containers", "update"]
        update_args += ["--rebase=" + image]
        update_args += values_list
        update_args += [name]

        if ctx.check_mode:
            return {"changed": True, "msg": "would update container " + name}

        update_res = ctx.run(update_args, mutates=True)
        if update_res.rc != 0:
            ctx.fail("failed to update container: " + update_res.stderr)
        changed = "Extracting" in update_res.stdout or "Copying blob" in update_res.stdout
        return {"changed": changed, "msg": update_res.stdout}

    if state == "latest" and not present:
        # Install as if latest requested for non-existing container
        install_args = [atomic_bin, "install"]
        install_args += ["--storage=" + backend]
        install_args += ["--name=" + name]
        if mode == "system":
            install_args += ["--system"]
        elif mode == "user":
            install_args += ["--user"]
        if rootfs:
            install_args += ["--rootfs=" + rootfs]
        install_args += values_list
        install_args += [image]

        if ctx.check_mode:
            return {"changed": True, "msg": "would install container " + name}

        install_res = ctx.run(install_args, mutates=True)
        if install_res.rc != 0:
            ctx.fail("failed to install container: " + install_res.stderr)
        changed = "Extracting" in install_res.stdout or "Copying blob" in install_res.stdout
        return {"changed": changed, "msg": install_res.stdout}

    if state == "absent":
        if not present:
            return {"changed": False, "msg": "The container is not present"}

        uninstall_args = [atomic_bin, "uninstall", "--storage=" + backend, name]
        if ctx.check_mode:
            return {"changed": True, "msg": "would uninstall container " + name}

        uninstall_res = ctx.run(uninstall_args, mutates=True)
        if uninstall_res.rc != 0:
            ctx.fail("failed to uninstall container: " + uninstall_res.stderr)
        return {"changed": True, "msg": uninstall_res.stdout}

    if state == "rollback":
        rollback_args = [atomic_bin, "containers", "rollback", name]
        if ctx.check_mode:
            return {"changed": True, "msg": "would rollback container " + name}

        rollback_res = ctx.run(rollback_args, mutates=True)
        if rollback_res.rc != 0:
            ctx.fail("failed to rollback container: " + rollback_res.stderr)
        changed = "Rolling back" in rollback_res.stdout
        return {"changed": changed, "msg": rollback_res.stdout}

    ctx.fail("unsupported state: " + state)
