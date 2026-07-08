def main(ctx, params):
    # Check swupd availability
    res = ctx.run(["which", "swupd"], mutates=False)
    if res.rc != 0:
        fail("Could not find swupd.")

    # Extract parameters
    name = params.get("name")
    state = params.get("state", "present")
    update = params.get("update", False)
    verify = params.get("verify", False)
    format_opt = params.get("format")
    manifest = params.get("manifest")
    url = params.get("url")
    contenturl = params.get("contenturl")
    versionurl = params.get("versionurl")

    # Enforce required_one_of and mutually_exclusive
    actions = [name, update, verify]
    count_set = 0
    for a in actions:
        if a != None:
            count_set = count_set + 1
    if count_set != 1:
        fail("One of name, update, or verify is required and they are mutually exclusive.")

    # Build command prefix
    cmd_prefix = ["swupd"]
    if format_opt != None:
        cmd_prefix.extend(["--format", str(format_opt)])
    if manifest != None:
        cmd_prefix.extend(["--manifest", str(manifest)])
    if url != None:
        cmd_prefix.extend(["--url", str(url)])
    elif contenturl != None:
        # Only add contenturl when not using update (per original logic)
        if not update and not verify:
            cmd_prefix.extend(["--contenturl", str(contenturl)])
    if versionurl != None:
        cmd_prefix.extend(["--versionurl", str(versionurl)])

    # Helper to run swupd commands
    def run_swupd(subcmd, mutates=False, extra_args=None):
        args = cmd_prefix + [subcmd]
        if extra_args != None:
            args = args + extra_args
        return ctx.run(args, mutates=mutates)

    # Check bundle installed status
    def is_bundle_installed(bundle):
        return ctx.file_exists("/usr/share/clear/bundles/" + bundle)

    # Check if update needed
    def needs_update():
        res = run_swupd("check-update", mutates=False)
        return res.rc == 0

    # Check if verify needed
    def needs_verify():
        res = run_swupd("verify", mutates=False)
        stdout = res.stdout or ""
        return "files did not match" in stdout

    # Determine action
    if update:
        # Update OS
        if ctx.check_mode:
            changed = needs_update()
            return {"changed": changed, "msg": "would update OS" if changed else "no updates available"}
        if not needs_update():
            return {"changed": False, "msg": "There are no updates available"}
        res = run_swupd("update", mutates=True)
        if res.rc != 0:
            fail("Failed to update OS: " + res.stderr)
        return {"changed": True, "msg": "Update successful", "stdout": res.stdout, "stderr": res.stderr}

    if verify:
        # Verify filesystem
        if ctx.check_mode:
            changed = needs_verify()
            return {"changed": changed, "msg": "would verify and fix filesystem" if changed else "no files changed"}
        if not needs_verify():
            return {"changed": False, "msg": "No files were changed"}
        res = run_swupd("verify", mutates=True, extra_args=["--fix"])
        if res.rc != 0:
            fail("Failed to verify OS: " + res.stderr)
        stdout = res.stdout or ""
        fixed = "missing files were replaced" in stdout or "files were fixed" in stdout or "files were deleted" in stdout
        if not fixed:
            return {"changed": False, "msg": "No files were changed", "stdout": stdout, "stderr": res.stderr}
        return {"changed": True, "msg": "Fix successful", "stdout": stdout, "stderr": res.stderr}

    if state == "present":
        # Install bundle
        if name == None:
            fail("bundle name is required for state=present")
        if ctx.check_mode:
            installed = is_bundle_installed(name)
            return {"changed": not installed, "msg": "would install bundle" if not installed else "already installed"}
        if is_bundle_installed(name):
            return {"changed": False, "msg": "Bundle %s is already installed" % name}
        res = run_swupd("bundle-add", mutates=True, extra_args=[name])
        if res.rc != 0:
            fail("Failed to install bundle " + name + ": " + res.stderr)
        return {"changed": True, "msg": "Bundle %s installed" % name, "stdout": res.stdout, "stderr": res.stderr}

    if state == "absent":
        # Remove bundle
        if name == None:
            fail("bundle name is required for state=absent")
        if ctx.check_mode:
            installed = is_bundle_installed(name)
            return {"changed": installed, "msg": "would remove bundle" if installed else "already absent"}
        if not is_bundle_installed(name):
            return {"changed": False, "msg": "Bundle %s not installed" % name}
        res = run_swupd("bundle-remove", mutates=True, extra_args=[name])
        if res.rc != 0:
            fail("Failed to remove bundle " + name + ": " + res.stderr)
        return {"changed": True, "msg": "Bundle %s removed" % name, "stdout": res.stdout, "stderr": res.stderr}

    fail("unsupported state: " + state)
