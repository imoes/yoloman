def main(ctx, params):
    # Verify rpm-ostree-based system
    if not ctx.file_exists("/run/ostree-booted"):
        fail("Module rpm_ostree_upgrade is only applicable for rpm-ostree based systems.")

    # Build command
    cmd = ["rpm-ostree", "upgrade"]
    
    os_name = params.get("os")
    if os_name:
        cmd += ["--os", os_name]
    
    if params.get("cache_only", False):
        cmd += ["--cache-only"]
    
    if params.get("allow_downgrade", False):
        cmd += ["--allow-downgrade"]
    
    if params.get("peer", False):
        cmd += ["--peer"]

    # Run the command (read-only probe since we only check output)
    res = ctx.run(cmd)
    out = res.stdout
    err = res.stderr

    if res.rc != 0:
        fail("rpm-ostree upgrade failed: " + err)

    if "No upgrade available." in out:
        return {"changed": False, "msg": out}
    
    # In check_mode, we predicted a change would occur (non-empty upgrade)
    if ctx.check_mode:
        return {"changed": True, "msg": "would perform upgrade: " + out}
    
    return {"changed": True, "msg": out}
