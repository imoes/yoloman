def main(ctx, params):
    name = params["name"]
    state = params.get("state", "latest")
    started = params.get("started", True)
    backend = params.get("backend")

    if state not in ("absent", "latest", "present"):
        fail("unsupported state: " + state)
    if backend and backend not in ("docker", "ostree"):
        fail("unsupported backend: " + backend)

    # Ensure atomic command is available
    res = ctx.run(["which", "atomic"])
    if res.rc != 0:
        fail("atomic command not found on host")

    def run_atomic(args, mutates=False):
        return ctx.run(["atomic"] + args, mutates=mutates)

    changed = False
    msg = ""

    if backend:
        if state == "absent":
            # images delete --storage=backend image
            res = run_atomic(["images", "delete", "--storage=" + backend, name], mutates=True)
            if res.skipped:
                msg = "would delete image " + name + " from " + backend + " backend"
                return {"changed": True, "msg": msg}
            if res.rc != 0:
                fail("failed to delete image " + name + ": " + res.stderr)
            changed = "Unable to find" not in res.stdout
            return {"changed": changed, "msg": res.stdout}

        # Pull with backend
        pull_args = ["pull", "--storage=" + backend, name]
        res = run_atomic(pull_args, mutates=True)
        if res.skipped:
            msg = "would pull image " + name + " to " + backend + " backend"
            return {"changed": True, "msg": msg}
        if res.rc != 0:
            fail("failed to pull image " + name + ": " + res.stderr)

        changed = "Extracting" in res.stdout or "Copying blob" in res.stdout

        if started:
            # run --storage=backend image
            run_args = ["run", "--storage=" + backend, name]
            res = run_atomic(run_args, mutates=True)
            if res.skipped:
                msg = "would run image " + name + " with backend " + backend
                return {"changed": changed, "msg": msg}
            if res.rc != 0:
                fail("failed to run image " + name + ": " + res.stderr)
            # In check_mode we already returned above, so here we can assume the run was performed
            changed = True

        return {"changed": changed, "msg": res.stdout}

    # No backend specified — default atomic behavior
    if state == "absent":
        res = run_atomic(["uninstall", name], mutates=True)
        if res.skipped:
            msg = "would uninstall image " + name
            return {"changed": True, "msg": msg}
        if res.rc != 0:
            fail("failed to uninstall image " + name + ": " + res.stderr)
        return {"changed": True, "msg": res.stdout}

    # state == 'present' or 'latest'
    is_upgraded = False

    if state == "latest":
        # atomic update --force image
        res = run_atomic(["update", "--force", name], mutates=True)
        if res.skipped:
            if "Image is up to date" in res.stdout:
                msg = "image " + name + " is already at latest version"
                return {"changed": False, "msg": msg}
            msg = "would upgrade image " + name
            return {"changed": True, "msg": msg}
        if res.rc != 0:
            fail("failed to update image " + name + ": " + res.stderr)
        if "Image is up to date" in res.stdout:
            is_upgraded = False
        else:
            is_upgraded = True

    # Run or install depending on started
    if started:
        res = run_atomic(["run", name], mutates=True)
        if res.skipped:
            msg = "would run image " + name
            return {"changed": True, "msg": msg}
        if res.rc != 0:
            if "already present" in res.stderr:
                return {"changed": is_upgraded, "msg": res.stderr}
            fail("failed to run image " + name + ": " + res.stderr)
        changed = True
    else:
        res = run_atomic(["install", name], mutates=True)
        if res.skipped:
            msg = "would install image " + name
            return {"changed": True, "msg": msg}
        if res.rc != 0:
            if "already present" in res.stderr:
                return {"changed": is_upgraded, "msg": res.stderr}
            fail("failed to install image " + name + ": " + res.stderr)
        changed = True

    return {"changed": changed, "msg": res.stdout}
