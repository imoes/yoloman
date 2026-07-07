def main(ctx, params):
    revision = params.get("revision", "latest")

    # Verify atomic host platform
    if not ctx.file_exists("/run/ostree-booted"):
        fail("Module atomic_host is applicable for Atomic Host Platforms only")

    # Get atomic binary path
    atomic = ctx.run(["which", "atomic"])
    if atomic.rc != 0:
        fail("atomic command not found")
    atomic_bin = atomic.stdout.strip()

    # Prepare command
    if revision == "latest":
        args = [atomic_bin, "host", "upgrade"]
    else:
        args = [atomic_bin, "host", "deploy", revision]

    # Execute command in check_mode (read-only for latest to detect if already on latest)
    if ctx.check_mode:
        if revision == "latest":
            # Probe current state
            probe = ctx.run(args, mutates=False, ok_codes=[0, 77])
            if probe.rc == 77:
                return {"changed": False, "msg": "Already on latest"}
            return {"changed": True, "msg": "would upgrade to latest"}
        else:
            return {"changed": True, "msg": "would deploy revision " + revision}

    # Actual execution (non-check_mode)
    res = ctx.run(args, mutates=True, ok_codes=[0, 77])
    if res.rc == 77 and revision == "latest":
        return {"changed": False, "msg": "Already on latest"}
    if res.rc != 0:
        fail("atomic command failed: " + res.stderr)
    return {"changed": True, "msg": res.stdout}
