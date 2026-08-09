def main(ctx, params):
    name = params.get("name")
    path = params.get("path")
    version = params.get("version")
    global_opt = params.get("global", False)
    production = params.get("production", False)
    registry = params.get("registry")
    state = params.get("state", "present")
    ignore_scripts = params.get("ignore_scripts", False)
    executable = params.get("executable")

    # Path validation
    if global_opt:
        if path != None:
            fail("Cannot specify path if doing global installation")
        res = ctx.run(["yarn", "global", "dir"], mutates=False)
        if res.rc != 0:
            fail("Failed to determine global directory: " + res.stderr)
        path = res.stdout.strip()
    else:
        if path == None:
            fail("Path must be specified when not using global arg")

    # State-specific validation
    if state == "absent" and name == None:
        fail("Package must be explicitly named when uninstalling.")

    # Resolve executable
    if executable == None:
        executable_cmd = ["yarn"]
    else:
        executable_cmd = executable.split(" ")

    # Build base command args
    base_args = executable_cmd[:]
    if global_opt:
        base_args.insert(0, "global")

    # Determine installed packages
    def list_packages():
        # Check for yarn.lock
        if not ctx.file_exists(path + "/yarn.lock"):
            return [], [name] if name else []

        # Run yarn list --depth=0 --json
        args = base_args + ["list", "--depth=0", "--json"]
        if production:
            args.append("--production")
        if ignore_scripts:
            args.append("--ignore-scripts")
        if registry:
            args.extend(["--registry", registry])

        res = ctx.run(args, mutates=False, ok_codes=[0,1])
        if res.rc != 0:
            fail("Yarn list command failed: " + res.stderr)

        installed = []
        for line in res.stdout.split("\n"):
            if line.strip() == "":
                continue
            if '"type"' in line and '"tree"' in line:
                # Extract name from JSON-like line
                start = line.find('"name":"')
                if start != -1:
                    start += len('"name":"')
                    end = line.find('"', start)
                    if end != -1:
                        dep_name = line[start:end]
                        # Strip version part
                        if "@" in dep_name:
                            dep_name = dep_name.rsplit("@", 1)[0]
                        installed.append(dep_name)

        missing = []
        if name != None and name not in installed:
            missing.append(name)
        return installed, missing

    # Determine outdated packages
    def list_outdated():
        if not ctx.file_exists(path + "/yarn.lock"):
            return []

        args = base_args + ["outdated", "--json"]
        if production:
            args.append("--production")
        if ignore_scripts:
            args.append("--ignore-scripts")
        if registry:
            args.extend(["--registry", registry])

        res = ctx.run(args, mutates=False, ok_codes=[0,1])
        if res.rc != 0:
            return []

        outdated = []
        lines = res.stdout.split("\n")
        if len(lines) < 2:
            return outdated

        line = lines[1]
        if '"body"' in line:
            # Extract body array — simplified extraction
            start = line.find('"body":')
            if start != -1:
                start = line.find('[', start)
                if start != -1:
                    end = line.find(']', start)
                    if end != -1:
                        arr = line[start:end+1]
                        # Parse names from array items
                        parts = arr.split(",")
                        for part in parts:
                            if len(part) > 2 and part[0] == '"' and part[-1] == '"':
                                outdated.append(part[1:-1])
        return outdated

    changed = False

    if state == "present":
        if name == None:
            changed = True
            args = base_args + ["install", "--non-interactive"]
            if production:
                args.append("--production")
            if ignore_scripts:
                args.append("--ignore-scripts")
            if registry:
                args.extend(["--registry", registry])
            res = ctx.run(args, mutates=True, ok_codes=[0])
            if res.rc != 0:
                fail("Failed to install packages: " + res.stderr)
        else:
            installed, missing = list_packages()
            if len(missing) > 0:
                changed = True
                ver_str = name
                if version != None:
                    ver_str += "@" + str(version)
                args = base_args + ["add", ver_str]
                if production:
                    args.append("--production")
                if ignore_scripts:
                    args.append("--ignore-scripts")
                if registry:
                    args.extend(["--registry", registry])
                res = ctx.run(args, mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to install package " + name + ": " + res.stderr)

    elif state == "latest":
        if name == None:
            changed = True
            args = base_args + ["install", "--non-interactive"]
            if production:
                args.append("--production")
            if ignore_scripts:
                args.append("--ignore-scripts")
            if registry:
                args.extend(["--registry", registry])
            res = ctx.run(args, mutates=True, ok_codes=[0])
            if res.rc != 0:
                fail("Failed to install packages: " + res.stderr)
        else:
            installed, missing = list_packages()
            outdated = list_outdated()
            if len(missing) > 0:
                changed = True
                ver_str = name
                if version != None:
                    ver_str += "@" + str(version)
                args = base_args + ["add", ver_str]
                if production:
                    args.append("--production")
                if ignore_scripts:
                    args.append("--ignore-scripts")
                if registry:
                    args.extend(["--registry", registry])
                res = ctx.run(args, mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to install package " + name + ": " + res.stderr)
            if len(outdated) > 0:
                changed = True
                args = base_args + ["upgrade", "--latest"]
                if production:
                    args.append("--production")
                if ignore_scripts:
                    args.append("--ignore-scripts")
                if registry:
                    args.extend(["--registry", registry])
                res = ctx.run(args, mutates=True, ok_codes=[0])
                if res.rc != 0:
                    fail("Failed to upgrade packages: " + res.stderr)

    else:  # state == absent
        installed, missing = list_packages()
        if name in installed:
            changed = True
            args = base_args + ["remove", name]
            if production:
                args.append("--production")
            if ignore_scripts:
                args.append("--ignore-scripts")
            if registry:
                args.extend(["--registry", registry])
            res = ctx.run(args, mutates=True, ok_codes=[0])
            if res.rc != 0:
                fail("Failed to remove package " + name + ": " + res.stderr)

    return {"changed": changed, "msg": "Operation completed successfully"}
