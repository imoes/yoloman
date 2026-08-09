def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    path = params.get("path")
    sparse = params.get("sparse", False)
    root_password = params.get("root_password")
    timeout = params.get("timeout", 600)
    config = params.get("config", "")
    create_options = params.get("create_options", "")
    install_options = params.get("install_options", "")
    attach_options = params.get("attach_options", "")

    # Validation: Solaris required
    facts = ctx.facts()
    if facts.get("os_family") != "solaris":
        fail("This module requires Solaris")

    # Validation: Zone name format using str methods instead of re
    def is_valid_zone_name(s):
        if len(s) == 0 or len(s) > 63:
            return False
        # First char must be alphanumeric
        if not (s[0].isalnum()):
            return False
        # Remaining chars must be alphanumeric, underscore, hyphen, or dot
        for i in range(1, len(s)):
            c = s[i]
            if not (c.isalnum() or c == "_" or c == "-" or c == "."):
                return False
        return True

    if not is_valid_zone_name(name):
        fail("Provided zone name is not a valid zone name. Please refer documentation for correct zone name specifications.")

    # Helper to get zone status
    def get_status():
        res = ctx.run([ctx.get_bin_path('zoneadm'), 'list', '-p', name], mutates=False)
        if res.rc == 0:
            parts = res.stdout.split(":")
            return parts[2] if len(parts) >= 3 else 'undefined'
        return 'undefined'

    # Helper: does zone exist?
    def zone_exists():
        res = ctx.run([ctx.get_bin_path('zoneadm'), 'list', name], mutates=False)
        return res.rc == 0

    # Helper: ensure zonepath exists
    def ensure_path():
        if not path:
            fail("Missing required argument: path")
        if not ctx.file_exists(path):
            ctx.run(["mkdir", "-p", path], mutates=True)

    # Configure zone via zonecfg
    def do_configure():
        ensure_path()
        if ctx.check_mode:
            return {"changed": True, "msg": "would configure zone"}
        # Create temp file via shell
        t = ctx.run(["mktemp"], mutates=False)
        if t.rc != 0:
            fail("Failed to create temporary file")
        tmpfile = t.stdout.strip()
        # Write zonecfg script
        create_flag = "" if sparse else "-b "
        script_lines = [
            "create " + create_flag + create_options,
            "set zonepath=" + path,
            config,
        ]
        script = "\n".join(script_lines) + "\n"
        ctx.file_write(tmpfile, script)
        res = ctx.run([ctx.get_bin_path('zonecfg'), '-z', name, '-f', tmpfile])
        # Cleanup
        ctx.run(["rm", "-f", tmpfile])
        if res.rc != 0:
            fail("Failed to configure zone: " + res.stderr)
        return {"changed": True, "msg": "zone configured"}

    # Install zone via zoneadm
    def do_install():
        res = ctx.run([ctx.get_bin_path('zoneadm'), '-z', name, 'install', install_options], mutates=True)
        if res.rc != 0:
            fail("Failed to install zone: " + res.stderr)
        # Only Solaris 10 needs sysidtool configuration
        dist = facts.get("distribution", "")
        os_version = facts.get("os_version", "0")
        if dist == "Solaris" and os_version.startswith("10"):
            do_configure_sysid()
        if root_password:
            do_configure_password()
        # SSH keys (not implemented; would require zonepath access, skipped for now)
        return {"changed": True, "msg": "zone installed"}

    # Configure zone system identification (Solaris 10)
    def do_configure_sysid():
        # In check_mode, just skip
        if ctx.check_mode:
            return
        # Skip if .UNCONFIGURED not present (zone already configured)
        if not ctx.file_exists(path + "/root/etc/.UNCONFIGURED"):
            return
        # Delete unconfigured marker
        ctx.run(["rm", "-f", path + "/root/etc/.UNCONFIGURED"])
        # Create noautoshutdown file
        ctx.run(["touch", path + "/root/noautoshutdown"])
        # Write nodename
        ctx.file_write(path + "/root/etc/nodename", name)
        # Write .sysIDtool.state
        state_content = """1       # System previously configured?
1       # Bootparams succeeded?
1       # System is on a network?
1       # Extended network information gathered?
0       # Autobinder succeeded?
1       # Network has subnets?
1       # root password prompted for?
1       # locale and term prompted for?
1       # security policy in place
1       # NFSv4 domain configured
0       # Auto Registration Configured
vt100
"""
        ctx.file_write(path + "/root/etc/.sysIDtool.state", state_content)

    # Configure root password
    def do_configure_password():
        shadow_path = path + "/root/etc/shadow"
        if not ctx.file_exists(shadow_path):
            return
        content = ctx.file_read(shadow_path)
        lines = content.split("\n")
        new_lines = []
        for line in lines:
            fields = line.split(":")
            if len(fields) > 1 and fields[0] == "root":
                fields[1] = root_password
                new_lines.append(":".join(fields))
            else:
                new_lines.append(line)
        new_content = "\n".join(new_lines)
        if content != new_content:
            ctx.file_write(shadow_path, new_content)

    # Boot zone
    def do_boot():
        res = ctx.run([ctx.get_bin_path('zoneadm'), '-z', name, 'boot'], mutates=True)
        if res.rc != 0:
            fail("Failed to boot zone: " + res.stderr)

        # Wait for console login (ttymon)
        elapsed = 0
        while elapsed < timeout:
            # Check if ttymon is running for console
            res = ctx.run(["ps", "-z", name, "-o", "args"], mutates=False)
            if res.rc == 0 and "ttymon" in res.stdout and "/dev/console" in res.stdout:
                break
            if ctx.check_mode:
                break
            # Sleep 10 seconds by calling out to sleep
            sleep_res = ctx.run(["sleep", "10"], mutates=False)
            elapsed = elapsed + 10
        return {"changed": True, "msg": "zone booted"}

    # Uninstall zone
    def do_uninstall():
        if ctx.check_mode:
            return {"changed": True, "msg": "would uninstall zone"}
        res = ctx.run([ctx.get_bin_path('zoneadm'), '-z', name, 'uninstall', '-F'], mutates=True)
        if res.rc != 0:
            fail("Failed to uninstall zone: " + res.stderr)
        return {"changed": True, "msg": "zone uninstalled"}

    # Stop zone
    def do_stop():
        if ctx.check_mode:
            return {"changed": True, "msg": "would stop zone"}
        res = ctx.run([ctx.get_bin_path('zoneadm'), '-z', name, 'halt'], mutates=True)
        if res.rc != 0:
            fail("Failed to stop zone: " + res.stderr)
        return {"changed": True, "msg": "zone stopped"}

    # Detach zone
    def do_detach():
        if ctx.check_mode:
            return {"changed": True, "msg": "would detach zone"}
        res = ctx.run([ctx.get_bin_path('zoneadm'), '-z', name, 'detach'], mutates=True)
        if res.rc != 0:
            fail("Failed to detach zone: " + res.stderr)
        return {"changed": True, "msg": "zone detached"}

    # Attach zone
    def do_attach():
        if ctx.check_mode:
            return {"changed": True, "msg": "would attach zone"}
        opts = attach_options.split() if attach_options else []
        res = ctx.run([ctx.get_bin_path('zoneadm'), '-z', name, 'attach'] + opts, mutates=True)
        if res.rc != 0:
            fail("Failed to attach zone: " + res.stderr)
        return {"changed": True, "msg": "zone attached"}

    # Destroy zone (delete)
    def do_destroy():
        if ctx.check_mode:
            return {"changed": True, "msg": "would destroy zone"}
        res = ctx.run([ctx.get_bin_path('zonecfg'), '-z', name, 'delete', '-F'], mutates=True)
        if res.rc != 0:
            fail("Failed to delete zone: " + res.stderr)
        return {"changed": True, "msg": "zone deleted"}

    # State handlers
    if state in ("running", "started"):
        if zone_exists():
            if get_status() == "running":
                return {"changed": False, "msg": "zone already running"}
            else:
                if get_status() != "installed":
                    fail("zone must be in installed state to boot; current state: " + get_status())
                boot_res = do_boot()
                return {"changed": boot_res["changed"], "msg": boot_res["msg"]}
        else:
            # Create and install first
            cfg = do_configure()
            if cfg["changed"]:
                # Install
                inst = do_install()
                if inst["changed"]:
                    boot_res = do_boot()
                    return {"changed": True, "msg": boot_res["msg"]}
                else:
                    boot_res = do_boot()
                    return {"changed": True, "msg": boot_res["msg"]}
            else:
                # Check mode: configure was skipped, proceed to install/boot
                if ctx.check_mode:
                    return {"changed": True, "msg": "would configure and install zone, then boot"}
                inst = do_install()
                boot_res = do_boot()
                return {"changed": True, "msg": boot_res["msg"]}

    elif state in ("present", "installed"):
        if zone_exists():
            return {"changed": False, "msg": "zone already exists"}
        else:
            cfg = do_configure()
            if cfg["changed"]:
                inst = do_install()
                return {"changed": True, "msg": inst["msg"]}
            else:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would configure and install zone"}
                inst = do_install()
                return {"changed": True, "msg": inst["msg"]}

    elif state == "stopped":
        if not zone_exists():
            fail("zone does not exist")
        if get_status() != "running":
            return {"changed": False, "msg": "zone already stopped"}
        stop_res = do_stop()
        return {"changed": stop_res["changed"], "msg": stop_res["msg"]}

    elif state == "absent":
        if not zone_exists():
            return {"changed": False, "msg": "zone does not exist"}
        if get_status() == "running":
            stop_res = do_stop()
        inst_res = do_uninstall()
        dest_res = do_destroy()
        return {"changed": True, "msg": dest_res["msg"]}

    elif state == "configured":
        if zone_exists():
            return {"changed": False, "msg": "zone already exists"}
        cfg = do_configure()
        return {"changed": cfg["changed"], "msg": cfg["msg"]}

    elif state == "detached":
        if not zone_exists():
            fail("zone does not exist")
        if get_status() == "configured":
            return {"changed": False, "msg": "zone already detached"}
        # Must stop first if running
        if get_status() == "running":
            stop_res = do_stop()
        det_res = do_detach()
        return {"changed": det_res["changed"], "msg": det_res["msg"]}

    elif state == "attached":
        if not zone_exists():
            fail("zone does not exist")
        if get_status() == "configured":
            att_res = do_attach()
            return {"changed": att_res["changed"], "msg": att_res["msg"]}
        else:
            return {"changed": False, "msg": "zone already attached"}

    else:
        fail("Unsupported state: " + state)
