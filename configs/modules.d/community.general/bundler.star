def main(ctx, params):
    state = params.get("state", "present")
    chdir = params.get("chdir")
    exclude_groups = params.get("exclude_groups")
    clean = params.get("clean", False)
    gemfile = params.get("gemfile")
    local = params.get("local", False)
    deployment_mode = params.get("deployment_mode", False)
    user_install = params.get("user_install", True)
    gem_path = params.get("gem_path")
    binstub_directory = params.get("binstub_directory")
    extra_args = params.get("extra_args")
    executable = params.get("executable")

    # Build base command
    if executable:
        cmd = executable.split(" ")
    else:
        cmd = ["bundle"]

    # State-specific logic
    if state == "present":
        cmd.append("install")
        if exclude_groups:
            cmd.extend(["--without", ":".join(exclude_groups)])
        if clean:
            cmd.append("--clean")
        if gemfile:
            cmd.extend(["--gemfile", gemfile])
        if local:
            cmd.append("--local")
        if deployment_mode:
            cmd.append("--deployment")
        if not user_install:
            cmd.append("--system")
        if gem_path:
            cmd.extend(["--path", gem_path])
        if binstub_directory:
            cmd.extend(["--binstubs", binstub_directory])
    elif state == "latest":
        cmd.append("update")
        if local:
            cmd.append("--local")
    else:
        fail("unsupported state: " + state)

    # Append extra args if provided
    if extra_args:
        cmd.extend(extra_args.split(" "))

    # In check_mode, run 'bundle check' to predict change
    if ctx.check_mode:
        check_cmd = cmd + ["--dry-run"] if state == "present" else cmd
        res = ctx.run(["bundle", "check"], cwd=chdir, mutates=False)
        changed = res.rc != 0
        msg = "would install" if changed else "already installed"
        return {"changed": changed, "msg": msg}

    # Actual execution
    res = ctx.run(cmd, cwd=chdir, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would install/update gems"}

    if res.rc != 0:
        fail("bundler failed: " + res.stderr)

    # Detect change: Ansible used 'Installing' in output; use simple heuristic
    changed = "Installing" in res.stdout or "Update" in res.stdout
    msg = "installed" if state == "present" else "updated"
    return {"changed": changed, "msg": msg}
