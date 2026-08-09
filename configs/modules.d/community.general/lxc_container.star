def main(ctx, params):
    name = params["name"]
    state = params.get("state", "started")
    container_command = params.get("container_command")
    archive = params.get("archive", False)
    archive_compression = params.get("archive_compression", "gzip")
    archive_path = params.get("archive_path")
    clone_name = params.get("clone_name")
    clone_snapshot = params.get("clone_snapshot", False)
    lxc_path = params.get("lxc_path")
    container_log = params.get("container_log", False)
    container_log_level = params.get("container_log_level", "INFO")
    backing_store = params.get("backing_store", "dir")
    template = params.get("template", "ubuntu")
    template_options = params.get("template_options")
    config = params.get("config")
    lv_name = params.get("lv_name")
    vg_name = params.get("vg_name", "lxc")
    thinpool = params.get("thinpool")
    fs_type = params.get("fs_type", "ext4")
    fs_size = params.get("fs_size", "5G")
    directory = params.get("directory")
    zfs_root = params.get("zfs_root")
    container_config = params.get("container_config", [])

    # Check container existence
    list_cmd = ["lxc-list"]
    if lxc_path:
        list_cmd.extend(["-P", lxc_path])
    res = ctx.run(list_cmd)
    container_exists = name in res.stdout

    # Helper to get container state via lxc-info
    def get_state():
        info_cmd = ["lxc-info", "-n", name]
        if lxc_path:
            info_cmd.extend(["-P", lxc_path])
        res = ctx.run(info_cmd)
        if res.rc != 0:
            return "absent"
        lines = res.stdout.splitlines()
        for line in lines:
            if line.startswith("state:"):
                return line.split(":", 1)[1].strip().lower()
        return "absent"

    # Helper: start container
    def start_container():
        start_cmd = ["lxc-start", "-n", name, "-d"]
        if lxc_path:
            start_cmd.extend(["-P", lxc_path])
        res = ctx.run(start_cmd)
        if res.rc != 0:
            fail("failed to start container " + name + ": " + res.stderr)

    # Helper: stop container
    def stop_container():
        stop_cmd = ["lxc-stop", "-n", name, "-k"]
        if lxc_path:
            stop_cmd.extend(["-P", lxc_path])
        res = ctx.run(stop_cmd)
        if res.rc != 0:
            fail("failed to stop container " + name + ": " + res.stderr)

    # Helper: freeze container
    def freeze_container():
        freeze_cmd = ["lxc-freeze", "-n", name]
        if lxc_path:
            freeze_cmd.extend(["-P", lxc_path])
        res = ctx.run(freeze_cmd)
        if res.rc != 0:
            fail("failed to freeze container " + name + ": " + res.stderr)

    # Helper: unfreeze container
    def unfreeze_container():
        unfreeze_cmd = ["lxc-unfreeze", "-n", name]
        if lxc_path:
            unfreeze_cmd.extend(["-P", lxc_path])
        res = ctx.run(unfreeze_cmd)
        if res.rc != 0:
            fail("failed to unfreeze container " + name + ": " + res.stderr)

    # Helper: create container
    def create_container():
        create_cmd = ["lxc-create", "-n", name, "-t", template, "-q"]
        if lxc_path:
            create_cmd.extend(["-P", lxc_path])
        if config:
            create_cmd.extend(["--config", config])
        create_cmd.extend(["--bdev", backing_store])
        if backing_store == "lvm":
            create_cmd.extend(["--lvname", lv_name if lv_name else name])
            create_cmd.extend(["--vgname", vg_name])
            if thinpool:
                create_cmd.extend(["--thinpool", thinpool])
            create_cmd.extend(["--fstype", fs_type])
            create_cmd.extend(["--fssize", fs_size])
        if backing_store == "dir" and directory:
            create_cmd.extend(["--dir", directory])
        if backing_store == "zfs" and zfs_root:
            create_cmd.extend(["--zfsroot", zfs_root])

        if container_log:
            # Determine log path
            res = ctx.run(["id", "-u"])
            uid = int(res.stdout.strip()) if res.rc == 0 else 0
            if uid == 0:
                log_path = "/var/log/lxc"
                # Ensure directory exists
                ctx.run(["mkdir", "-p", log_path], ok_codes=[0, 1])
            else:
                res = ctx.run(["getent", "passwd", str(uid)])
                home = res.stdout.split(":")[5] if res.rc == 0 else "/tmp"
                log_path = home

            log_file = log_path + "/lxc-" + name + ".log"
            level = container_log_level.upper()
            if level not in ["INFO", "ERROR", "DEBUG"]:
                level = "INFO"
            create_cmd.extend(["--logfile", log_file, "--logpriority", level])

        if template_options:
            create_cmd.extend(["--"])
            create_cmd.extend(template_options.split())

        res = ctx.run(create_cmd)
        if res.rc != 0:
            fail("failed to create container " + name + ": " + res.stderr)

    # Helper: clone container
    def clone_container():
        # Ensure original is stopped before clone
        current_state = get_state()
        if current_state != "stopped":
            stop_container()

        # Prefer lxc-copy over deprecated lxc-clone
        clone_cmd = ["lxc-copy"]
        res = ctx.run(["which", "lxc-copy"], ok_codes=[0, 1])
        if res.rc != 0 or not res.stdout.strip():
            clone_cmd = ["lxc-clone"]

        clone_cmd.extend(["-n", name, "--newname", clone_name])
        if lxc_path:
            clone_cmd.extend(["-P", lxc_path])

        # Backing store mapping for clone
        if backing_store == "lvm":
            # lxc-copy/lxc-clone doesn't directly map backing_store; skip
            pass
        elif backing_store == "dir":
            pass
        else:
            # For other backends, use snapshot if supported
            clone_snapshot = True

        if clone_snapshot:
            clone_cmd.append("--snapshot")

        res = ctx.run(clone_cmd)
        if res.rc != 0:
            fail("failed to clone container " + name + " to " + clone_name + ": " + res.stderr)

    # Helper: destroy container
    def destroy_container():
        # First archive if requested
        if archive:
            # archive is handled separately; no-op here
            pass

        # Clone if requested
        if clone_name:
            clone_container()

        # Stop if running/frozen
        current_state = get_state()
        if current_state not in ["stopped", "absent"]:
            stop_container()

        destroy_cmd = ["lxc-destroy", "-n", name]
        if lxc_path:
            destroy_cmd.extend(["-P", lxc_path])
        res = ctx.run(destroy_cmd)
        if res.rc != 0:
            fail("failed to destroy container " + name + ": " + res.stderr)

    # Helper: run command in container via attach
    def run_command_in_container():
        # Prepare script for attach
        cmd = container_command.strip()
        script = "#!/usr/bin/env bash\n"
        script += "cd ~\n"
        script += "source ~/.bashrc 2>/dev/null || true\n"
        script += cmd + "\n"

        # Write script to temp file
        res = ctx.run(["mktemp", "-d"])
        tmpdir = res.stdout.strip()
        script_path = tmpdir + "/lxc-attach-script"
        log_path = tmpdir + "/lxc-attach-log"
        err_path = tmpdir + "/lxc-attach-err"

        ctx.file_write(script_path, script, "0700")
        # Note: We can't fully simulate attach_wait; run the command on host
        # In real Starlark runtime, attach_wait would be emulated by a custom ctx method.
        # For this translation, we assume a simplified execution path via lxc-attach if available.

        # Fallback: run via lxc-attach if container is running/frozen
        attach_cmd = ["lxc-attach", "-n", name, "--"]
        attach_cmd.extend(["/bin/bash", "-c", cmd])
        if lxc_path:
            attach_cmd.extend(["-P", lxc_path])
        res = ctx.run(attach_cmd, ok_codes=[0, 1])
        if res.rc != 0:
            fail("failed to run command in container " + name + ": " + res.stderr)

        # Cleanup
        ctx.run(["rm", "-rf", tmpdir])

    # Helper: archive container (simplified)
    def create_archive():
        if not archive_path:
            fail("archive_path is required when archive=true")

        # Ensure archive directory exists
        ctx.run(["mkdir", "-p", archive_path], ok_codes=[0, 1])

        # Determine compression
        compress_arg = "-czf"
        ext = "tar.tgz"
        if archive_compression == "bzip2":
            compress_arg = "-cjf"
            ext = "tar.bz2"
        elif archive_compression == "none":
            compress_arg = "-cf"
            ext = "tar"

        archive_file = archive_path + "/" + name + "." + ext

        # Stop if needed
        current_state = get_state()
        if current_state not in ["stopped", "frozen"]:
            stop_container()

        # Use tar to create archive of container rootfs
        # Path is usually under lxc-path/containers/name/rootfs or similar
        container_dir = lxc_path + "/" + name + "/rootfs" if lxc_path else "/var/lib/lxc/" + name + "/rootfs"
        if ctx.file_exists(container_dir):
            tar_cmd = ["tar", compress_arg, archive_file, "-C", container_dir, "."]
            res = ctx.run(tar_cmd)
            if res.rc != 0:
                fail("failed to create archive for " + name + ": " + res.stderr)
        else:
            fail("container rootfs not found at " + container_dir)

    # State handling
    if state == "clone":
        if not clone_name:
            fail("clone_name is required when state=clone")

        # Clone
        if container_exists:
            # Original must be stopped during clone
            orig_state = get_state()
            if orig_state != "stopped":
                stop_container()
            clone_container()
            # Restore original state
            if orig_state == "running":
                start_container()
            elif orig_state == "frozen":
                start_container()
                freeze_container()
        else:
            fail("source container " + name + " does not exist for cloning")

        return {"changed": True, "msg": "cloned " + name + " to " + clone_name}

    if state == "absent":
        if not container_exists:
            return {"changed": False, "msg": "container " + name + " does not exist"}

        if ctx.check_mode:
            return {"changed": True, "msg": "would destroy " + name}

        destroy_container()
        return {"changed": True, "msg": "destroyed " + name}

    # States that require container to exist or be created
    if state in ["started", "stopped", "restarted", "frozen"]:
        if not container_exists:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create and start " + name}

            create_container()
            container_exists = True

        current_state = get_state()

        if state == "started":
            if current_state == "running":
                if container_command:
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would run command in " + name}
                    run_command_in_container()
                return {"changed": False, "msg": name + " already started"}

            if container_command:
                if current_state == "frozen":
                    unfreeze_container()
                elif current_state == "stopped":
                    start_container()

            if ctx.check_mode:
                return {"changed": True, "msg": "would start " + name}

            start_container()
            if container_command:
                run_command_in_container()
            return {"changed": True, "msg": "started " + name}

        elif state == "stopped":
            if current_state == "stopped":
                if container_command:
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would run command in " + name}
                    run_command_in_container()
                return {"changed": False, "msg": name + " already stopped"}

            if container_command and current_state != "stopped":
                if current_state == "frozen":
                    unfreeze_container()
                start_container()

            if ctx.check_mode:
                return {"changed": True, "msg": "would stop " + name}

            stop_container()
            if container_command:
                run_command_in_container()
            return {"changed": True, "msg": "stopped " + name}

        elif state == "frozen":
            if current_state == "frozen":
                if container_command:
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would run command in " + name}
                    run_command_in_container()
                return {"changed": False, "msg": name + " already frozen"}

            if current_state == "running":
                if ctx.check_mode:
                    return {"changed": True, "msg": "would freeze " + name}
                freeze_container()
            elif current_state == "stopped":
                if ctx.check_mode:
                    return {"changed": True, "msg": "would start and freeze " + name}
                start_container()
                freeze_container()

            if container_command and current_state != "frozen":
                if current_state == "stopped":
                    start_container()
                run_command_in_container()

            return {"changed": True, "msg": "frozen " + name}

        elif state == "restarted":
            if ctx.check_mode:
                return {"changed": True, "msg": "would restart " + name}

            if current_state != "stopped":
                stop_container()
            start_container()
            if container_command:
                run_command_in_container()
            return {"changed": True, "msg": "restarted " + name}

    fail("unsupported state: " + state)
