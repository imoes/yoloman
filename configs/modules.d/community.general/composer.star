def main(ctx, params):
    command = params.get("command", "install")
    arguments = params.get("arguments", "")
    global_command = params.get("global_command", False)
    working_dir = params.get("working_dir")
    php_path = params.get("executable")
    composer_executable = params.get("composer_executable")

    # Validation: required working_dir for non-global commands
    if not global_command and working_dir == None:
        fail("working_dir is required when global_command=false")

    # Build base command: php + composer + global flag
    if php_path == None:
        res = ctx.run(["which", "php"], mutates=False)
        if res.rc != 0:
            fail("php not found in PATH and executable not specified")
        php_path = res.stdout.strip()
    else:
        # Validate executable exists
        if not ctx.file_exists(php_path):
            fail("PHP executable '%s' not found" % php_path)

    if composer_executable == None:
        res = ctx.run(["which", "composer"], mutates=False)
        if res.rc != 0:
            fail("composer not found in PATH and composer_executable not specified")
        composer_path = res.stdout.strip()
    else:
        if not ctx.file_exists(composer_executable):
            fail("Composer executable '%s' not found" % composer_executable)
        composer_path = composer_executable

    # Build base command parts
    base_cmd = [php_path, composer_path]
    if global_command:
        base_cmd.append("global")
    base_cmd.append(command)

    # Get available options by running `composer help <command> --format=json`
    help_cmd = base_cmd + ["help", command, "--no-interaction", "--format=json"]
    res = ctx.run(help_cmd, mutates=False)
    if res.rc != 0:
        fail("Failed to get composer command help: " + res.stderr)

    help_output = res.stdout + res.stderr

    def has_option(flag):
        return ("--" + flag) in help_output

    # Build options list based on parameters
    options = []

    # Default options: no-ansi, no-interaction, no-progress
    default_opts = ["no-ansi", "no-interaction", "no-progress"]
    for i in range(len(default_opts)):
        opt = default_opts[i]
        if has_option(opt):
            options.append("--" + opt)

    # Parameter-based options
    opt_map = {
        "prefer_source": "prefer-source",
        "prefer_dist": "prefer-dist",
        "no_dev": "no-dev",
        "no_scripts": "no-scripts",
        "no_plugins": "no-plugins",
        "apcu_autoloader": "apcu-autoloader",
        "optimize_autoloader": "optimize-autoloader",
        "classmap_authoritative": "classmap-authoritative",
        "ignore_platform_reqs": "ignore-platform-reqs",
    }

    for param_name in opt_map:
        option_name = opt_map[param_name]
        if params.get(param_name):
            if has_option(option_name):
                options.append("--" + option_name)

    # Build full command
    cmd = base_cmd + options
    if working_dir:
        cmd.extend(["--working-dir", working_dir])
    if arguments:
        cmd.extend(arguments.split())

    # Check mode handling: use dry-run if supported
    if ctx.check_mode:
        if has_option("dry-run"):
            cmd.append("--dry-run")
        else:
            return {"changed": False, "skipped": True, "msg": "command '%s' does not support check mode, skipping" % command}

    # Execute the command
    res = ctx.run(cmd, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would run composer " + command}

    if res.rc != 0:
        fail("composer " + command + " failed: " + res.stderr)

    # Determine changed status
    output = res.stdout + res.stderr
    no_change_phrases = ["Nothing to install or update", "Nothing to install, update or remove"]
    changed = True
    for i in range(len(no_change_phrases)):
        if no_change_phrases[i] in output:
            changed = False
            break

    return {"changed": changed, "msg": output.strip(), "data": {"stdout": output}}
