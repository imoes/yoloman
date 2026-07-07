def main(ctx, params):
    command = params["command"]
    project_path = params["project_path"]
    virtualenv = params.get("virtualenv")
    apps = params.get("apps")
    cache_table = params.get("cache_table")
    clear = params.get("clear", False)
    database = params.get("database")
    failfast = params.get("failfast", False)
    fixtures = params.get("fixtures")
    link = params.get("link", False)
    merge = params.get("merge", False)
    pythonpath = params.get("pythonpath")
    settings = params.get("settings")
    skip = params.get("skip", False)
    testrunner = params.get("testrunner")
    ack_venv_creation_deprecation = params.get("ack_venv_creation_deprecation", False)

    # Check required command and deprecation warnings
    deprecated_commands = {
        "cleanup": "clearsessions",
        "syncdb": "migrate",
        "validate": "check",
    }
    if command in deprecated_commands:
        # Note: In Starlark we can't actually deprecate via ctx.deprecate(),
        # so we just proceed with the translation logic.
        # The real deprecation behavior would be handled in the surrounding tooling.
        pass

    # Command allowed parameter mapping (simplified)
    allowed_params_map = {
        "cleanup": [],
        "createcachetable": ["cache_table", "database"],
        "flush": ["database"],
        "loaddata": ["database", "fixtures"],
        "syncdb": ["database"],
        "test": ["failfast", "testrunner", "apps"],
        "validate": [],
        "migrate": ["apps", "skip", "merge", "database"],
        "collectstatic": ["clear", "link"],
    }

    # Check parameter compatibility
    allowed = allowed_params_map.get(command)
    if allowed == None:
        fail("Unknown django command: " + command)

    specific_params = ["apps", "clear", "database", "failfast", "fixtures", "testrunner"]
    for p in specific_params:
        if params.get(p) and p not in allowed:
            fail(p + " param is incompatible with command=" + command)

    # Required params per command
    required_map = {
        "loaddata": ["fixtures"],
    }
    required = required_map.get(command, [])
    for r in required:
        if not params.get(r):
            fail(r + " param is required for command=" + command)

    # Ensure virtualenv (with deprecation behavior for missing venv)
    if virtualenv != None:
        venv_bin = virtualenv + "/bin"
        activate_path = venv_bin + "/activate"
        if not ctx.file_exists(activate_path):
            if not ack_venv_creation_deprecation:
                # In real environment, would ctx.deprecate() here
                pass
            # Create virtualenv if missing
            # Note: This is a potential breaking change in v9.0.0 — we proceed per current spec
            # ctx.run(["virtualenv", virtualenv], mutates=True)
            fail("virtualenv at " + virtualenv + " does not exist and creation is deprecated; set ack_venv_creation_deprecation=true")
        # Prepend venv bin to PATH in env (simulate via context)
        # Starlark ctx has no direct env manipulation; assume PATH already includes it
        # or handle via explicit environment override in ctx.run if available

    # Build command list
    cmd = ["./manage.py"] + command.split()

    # Add --noinput for specific commands if not present
    noinput_commands = ["flush", "syncdb", "migrate", "test", "collectstatic"]
    if command in noinput_commands and "--noinput" not in command.split():
        cmd.append("--noinput")

    # General params
    for p in ["settings", "pythonpath", "database"]:
        v = params.get(p)
        if v:
            cmd.extend(["--" + p.replace("pythonpath", "python_path"), v])

    # Boolean flags
    if clear:
        cmd.append("--clear")
    if failfast:
        cmd.append("--failfast")
    if skip:
        cmd.append("--skip")
    if merge:
        cmd.append("--merge")
    if link:
        cmd.append("--link")

    # End-of-command params
    if apps:
        cmd.extend(apps.split())
    if cache_table:
        cmd.append(cache_table)
    if fixtures:
        cmd.extend(fixtures.split())

    # Run command
    res = ctx.run(cmd, mutates=True, cwd=project_path)
    if res.skipped:
        return {"changed": True, "msg": "would run django manage " + command}
    if res.rc != 0:
        if command == "createcachetable" and "already exists" in res.stderr:
            out = "already exists."
            changed = False
        elif "Unknown command:" in res.stderr:
            fail("Unknown django command: " + command)
        else:
            fail("django manage " + command + " failed: " + res.stderr)

    # Determine changed status
    out = res.stdout
    changed = False

    def _filter(line):
        if command == "createcachetable":
            return "already exists" not in line
        elif command == "flush":
            return "Installed" in line and "Installed 0 object" not in line
        elif command == "loaddata":
            return "Installed" in line and "Installed 0 object" not in line
        elif command == "syncdb":
            return "Creating table " in line or ("Installed" in line and "Installed 0 object" not in line)
        elif command == "migrate":
            return "Migrating forwards " in line or ("Installed" in line and "Installed 0 object" not in line) or "Applying" in line
        elif command == "collectstatic":
            return line and "0 static files" not in line
        else:
            return False

    # Default filter logic
    if command in ["flush", "loaddata", "syncdb", "migrate", "collectstatic"]:
        lines = out.split("\n")
        filtered = [l for l in lines if _filter(l)]
        changed = len(filtered) > 0
    elif command == "createcachetable":
        changed = "already exists" not in out

    return {"changed": changed, "msg": "ran django manage " + command}
