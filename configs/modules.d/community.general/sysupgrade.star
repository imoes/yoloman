def main(ctx, params):
    # Check OpenBSD platform (sysupgrade only exists on OpenBSD)
    facts = ctx.facts()
    if facts.get("os_family") != "OpenBSD":
        fail("sysupgrade module only works on OpenBSD systems")

    # Build sysupgrade command arguments
    cmd = ["/usr/sbin/sysupgrade"]
    changed = False

    # Determine upgrade type (snapshot vs release)
    if params.get("snapshot", False):
        cmd.append("-s")
        if params.get("force", False):
            cmd.append("-f")
    else:
        cmd.append("-r")

    if params.get("keep_files", False):
        cmd.append("-k")

    if params.get("fetch_only", True):
        cmd.append("-n")

    if params.get("installurl") != None:
        cmd.append(params.get("installurl"))

    # Run sysupgrade command
    res = ctx.run(cmd, mutates=True)

    # Handle command execution
    if res.skipped:
        # In check_mode: determine if change would occur
        if params.get("fetch_only", True):
            # Fetch-only mode creates /bsd.upgrade but doesn't reboot
            # Assume changed if fetch_only == True (will create upgrade file)
            changed = True
        else:
            # Will reboot - Ansible can't continue gracefully
            return {"changed": True, "msg": "would reboot system to apply upgrade", "rc": res.rc, "stdout": res.stdout, "stderr": res.stderr}

    if res.rc != 0:
        fail("sysupgrade command failed rc=%d, stdout=%s, stderr=%s" % (res.rc, res.stdout, res.stderr))

    # Parse output to determine if changed
    stdout_lower = res.stdout.lower()
    if stdout_lower.find("already on latest snapshot") >= 0:
        changed = False
    elif stdout_lower.find("upgrade on next reboot") >= 0:
        changed = True

    return {
        "changed": changed,
        "rc": res.rc,
        "stdout": res.stdout,
        "stderr": res.stderr
    }
