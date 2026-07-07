def main(ctx, params):
    project_src = params["project_src"]
    policy = params.get("policy", "always")
    files = params.get("files")
    env_files = params.get("env_files")
    project_name = params.get("project_name")
    profiles = params.get("profiles")
    cli_context = params.get("cli_context")
    docker_cli = params.get("docker_cli", "docker")

    # Build base docker compose arguments
    args = [docker_cli, "compose"]

    # Project-specific options
    if project_name:
        args.extend(["--project-name", project_name])
    if files:
        for f in files:
            args.extend(["-f", f])
    if env_files:
        for ef in env_files:
            args.extend(["--env-file", ef])
    if profiles:
        for pr in profiles:
            args.extend(["--profile", pr])
    if cli_context:
        args.extend(["--context", cli_context])

    args.extend(["pull"])

    if policy != "always":
        args.extend(["--policy", policy])

    if ctx.check_mode:
        args.append("--dry-run")

    args.extend(["--", project_src])

    # Probe: in check_mode, we simulate without mutating; in normal mode, we execute
    res = ctx.run(args, mutates=not ctx.check_mode)
    if res.skipped:
        # Predicted change but no mutation happened
        return {"changed": True, "msg": "would pull images for project in " + project_src}

    if res.rc != 0:
        fail("docker compose pull failed: " + res.stderr)

    # Parse stderr for pull events (simplified: report change if any output indicates pulling)
    stderr_lines = res.stderr.splitlines() if res.stderr else []
    pull_actions = [line for line in stderr_lines if "Pulling" in line]

    if ctx.check_mode:
        changed = len(pull_actions) > 0
        msg = "would pull " + str(len(pull_actions)) + " image(s)" if changed else "all images already present"
        return {"changed": changed, "msg": msg}

    changed = len(pull_actions) > 0
    msg = "pulled " + str(len(pull_actions)) + " image(s)" if changed else "all images already present"
    return {"changed": changed, "msg": msg}
