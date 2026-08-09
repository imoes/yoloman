def main(ctx, params):
    dest = params["dest"]
    parent = params["name"]
    version = params.get("version", "head")
    force = params.get("force", False)
    bzr_path = params.get("executable") or _find_bzr(ctx)

    if not dest.startswith("/"):
        fail("dest must be an absolute path: " + dest)

    bzrconfig = dest + "/.bzr/branch/branch.conf"

    # Probe current state
    exists = ctx.file_exists(bzrconfig)

    if not exists:
        # Clone
        dest_dirname = "/".join(dest.split("/")[:-1]) if "/" in dest else ""
        if dest_dirname and not ctx.file_exists(dest_dirname):
            ctx.run(["mkdir", "-p", dest_dirname])
        if version.lower() != "head":
            res = ctx.run([bzr_path, "branch", "-r", version, parent, dest], mutates=True)
        else:
            res = ctx.run([bzr_path, "branch", parent, dest], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would clone " + parent + " to " + dest}
        if res.rc != 0:
            fail("clone failed: " + res.stderr)
        return {"changed": True, "msg": "cloned " + parent + " to " + dest}

    # Branch already exists - get current version
    before_res = ctx.run([bzr_path, "revno"], cwd=dest)
    if before_res.rc != 0:
        fail("failed to get current version: " + before_res.stderr)
    before = before_res.stdout.strip()

    # Check for local modifications
    status_res = ctx.run([bzr_path, "status", "-S"], cwd=dest)
    lines = status_res.stdout.splitlines() if status_res.stdout else []
    lines = [line for line in lines if not line.startswith("? ")]
    local_mods = len(lines) > 0

    # Reset (revert) working tree
    revert_res = ctx.run([bzr_path, "revert"], mutates=True, cwd=dest)
    if revert_res.skipped:
        return {
            "changed": local_mods or True,
            "msg": "would revert branch " + dest + ("" if not local_mods else " (has local modifications)")
        }
    if revert_res.rc != 0:
        fail("revert failed: " + revert_res.stderr)

    # Fetch (pull)
    if version.lower() != "head":
        pull_res = ctx.run([bzr_path, "pull", "-r", version], cwd=dest)
    else:
        pull_res = ctx.run([bzr_path, "pull"], cwd=dest)
    if pull_res.rc != 0:
        fail("pull failed: " + pull_res.stderr)

    # Switch to version
    if version.lower() != "head":
        switch_res = ctx.run([bzr_path, "revert", "-r", version], cwd=dest)
    else:
        switch_res = ctx.run([bzr_path, "revert"], cwd=dest)
    if switch_res.rc != 0:
        fail("switch version failed: " + switch_res.stderr)

    # Get new version
    after_res = ctx.run([bzr_path, "revno"], cwd=dest)
    if after_res.rc != 0:
        fail("failed to get after version: " + after_res.stderr)
    after = after_res.stdout.strip()

    # Determine if changed
    changed = (before != after) or local_mods

    msg = "branch updated"
    if before == after and not local_mods:
        msg = "branch already up to date"

    return {"changed": changed, "msg": msg}


def _find_bzr(ctx):
    # Use which to locate bzr
    res = ctx.run(["which", "bzr"])
    if res.rc == 0:
        return res.stdout.strip()
    fail("bzr executable not found")
