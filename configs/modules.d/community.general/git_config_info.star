def text_to_dict(lines):
    config_values = {}
    for item in lines:
        if item == "":
            continue
        idx = item.find("\n")
        if idx == -1:
            continue
        k = item[:idx]
        v = item[idx + 1:]
        if k in config_values:
            config_values[k].append(v)
        else:
            config_values[k] = [v]
    return config_values


def build_args(ctx, name, path, scope):
    git_path = ctx.run(["which", "git"], mutates=False).stdout.strip()
    if git_path == "" or git_path == None:
        fail("git binary not found in PATH")
    args = [git_path, "config", "--includes", "--null", "--" + scope]
    if scope == "file":
        args.append(path)
    if name != None and name != "":
        args.extend(["--get-all", name])
    else:
        args.append("--list")
    return args


def main(ctx, params):
    name = params.get("name")
    path = params.get("path")
    scope = params.get("scope", "system")

    # Validate required_if conditions manually
    if scope in ["local", "file"]:
        if path == None or path == "":
            fail("scope is '" + scope + "' but 'path' is missing or empty")

    # Build args
    args = build_args(ctx, name, path, scope)

    # Determine working directory
    run_cwd = path if scope == "local" else "/"

    # Run git config
    res = ctx.run(args, cwd=run_cwd, mutates=False)
    if res.rc == 128 and "unable to read config file" in res.stderr:
        # Nothing has been set at the given scope
        output_lines = []
    elif res.rc >= 2:
        fail("git config failed with rc=" + str(res.rc) + ": " + res.stderr)
    else:
        # Strip null separators and split
        raw_out = res.stdout.strip("\0") if res.stdout else ""
        output_lines = raw_out.split("\0") if raw_out else []

    # Build result
    if name != None and name != "":
        first_value = output_lines[0] if output_lines else ""
        config_values = {name: output_lines}
        return {"changed": False, "msg": "", "config_value": first_value, "config_values": config_values}
    else:
        config_values = text_to_dict(output_lines)
        return {"changed": False, "msg": "", "config_value": "", "config_values": config_values}
