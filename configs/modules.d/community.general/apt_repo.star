def main(ctx, params):
    repo = params["repo"]
    state = params.get("state", "present")
    remove_others = params.get("remove_others", False)
    update_db = params.get("update", False)

    # Check system compatibility: only ALT-based distros have apt-repo
    facts = ctx.facts()
    os_family = facts.get("os_family", "").lower()
    if os_family not in ("altlinux", "alt"):
        fail("apt_repo module only works on ALT-based distributions (e.g., ALT Linux)")

    # Verify apt-repo binary exists
    if not ctx.file_exists("/usr/bin/apt-repo"):
        fail("cannot find /usr/bin/apt-repo")

    # Probe current repositories (read-only)
    res_current = ctx.run(["/usr/bin/apt-repo"], mutates=False)
    if res_current.rc != 0:
        fail("failed to list repositories: " + res_current.stderr)
    old_repos = res_current.stdout

    # Determine desired state
    changed = False
    if state == "present":
        if remove_others:
            # Add repo first to validate, then clear all and re-add
            res = ctx.run(["/usr/bin/apt-repo", "add", repo], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would add repository and remove others"}
            if res.rc != 0:
                fail("failed to add repository: " + res.stderr)

            res = ctx.run(["/usr/bin/apt-repo", "rm", "all"], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would remove all repositories"}
            if res.rc != 0:
                fail("failed to remove all repositories: " + res.stderr)

            res = ctx.run(["/usr/bin/apt-repo", "add", repo], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would re-add repository after cleaning"}
            if res.rc != 0:
                fail("failed to re-add repository: " + res.stderr)
        else:
            # Add single repo
            res = ctx.run(["/usr/bin/apt-repo", "add", repo], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would add repository"}
            if res.rc != 0:
                fail("failed to add repository: " + res.stderr)

    elif state == "absent":
        # Remove repo
        res = ctx.run(["/usr/bin/apt-repo", "rm", repo], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove repository"}
        if res.rc != 0:
            fail("failed to remove repository: " + res.stderr)

    else:
        fail("unsupported state: " + state)

    # Update package database if requested
    if update_db:
        res = ctx.run(["/usr/bin/apt-repo", "update"], mutates=True)
        if res.skipped:
            # In check_mode, update would run; return predicted changed
            pass
        elif res.rc != 0:
            fail("failed to update repository cache: " + res.stderr)

    # Probe new state and compute changed
    res_new = ctx.run(["/usr/bin/apt-repo"], mutates=False)
    if res_new.rc != 0:
        fail("failed to list repositories after change: " + res_new.stderr)
    new_repos = res_new.stdout
    changed = (old_repos != new_repos)

    return {"changed": changed, "msg": "repository " + state + "d successfully", "repo": repo, "state": state}
