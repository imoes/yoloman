def main(ctx, params):
    name = params.get("name")
    include_deps = params.get("include_deps", False)
    include_injected = params.get("include_injected", False)
    include_raw = params.get("include_raw", False)
    executable = params.get("executable")

    # Build pipx command
    if executable != None:
        cmd = [executable, "list", "--json"]
    else:
        facts = ctx.facts()
        python_exec = facts.get("python", {}).get("executable", "python")
        cmd = [python_exec, "-m", "pipx", "list", "--json"]

    # Execute pipx list command
    res = ctx.run(cmd)
    if res.rc != 0:
        fail("failed to run pipx list: " + res.stderr)

    raw_data = res.stdout.strip()
    if raw_data == "":
        fail("pipx list --json returned empty output")

    # Parse JSON manually (safe for known-valid pipx output)
    out = _parse_pipx_json(raw_data)

    raw_output = None
    if include_raw:
        raw_output = out

    # Extract venvs dict
    venvs = out.get("venvs", {})
    if type(venvs) != "dict":
        fail("unexpected pipx list output: venvs is not a dict")

    # Filter by name if provided
    if name != None:
        if name in venvs:
            venvs = {name: venvs[name]}
        else:
            venvs = {}

    application = []
    for venv_name, venv in venvs.items():
        if type(venv) != "dict":
            fail("unexpected pipx list output: venv entry is not a dict")
        metadata = venv.get("metadata", {})
        if type(metadata) != "dict":
            fail("unexpected pipx list output: metadata is not a dict")

        main_pkg = metadata.get("main_package", {})
        if type(main_pkg) != "dict":
            fail("unexpected pipx list output: main_package is not a dict")

        entry = {
            "name": venv_name,
            "version": main_pkg.get("package_version", "")
        }

        if include_injected:
            injected_pkgs = metadata.get("injected_packages", {})
            if type(injected_pkgs) == "dict":
                entry["injected"] = {}
                for pkg_name, pkg_info in injected_pkgs.items():
                    if type(pkg_info) == "dict":
                        entry["injected"][pkg_name] = pkg_info.get("package_version", "")

        if include_deps:
            app_paths_deps = main_pkg.get("app_paths_of_dependencies", [])
            if type(app_paths_deps) == "list":
                entry["dependencies"] = app_paths_deps

        application.append(entry)

    if include_raw:
        return {"changed": False, "msg": "retrieved pipx info", "data": {
            "application": application,
            "raw_output": raw_output,
            "cmd": cmd
        }}

    return {"changed": False, "msg": "retrieved pipx info", "data": {
        "application": application,
        "cmd": cmd
    }}


def _parse_pipx_json(s):
    # Minimal JSON parser for known-valid pipx --json output
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        fail("invalid JSON: not an object")
    s = s[1:-1].strip()
    result = {}
    # Split top-level comma-separated key-value pairs
    depth = 0
    current = ""
    for i in range(len(s)):
        c = s[i]
        if c in "{[":
            depth += 1
        elif c in "}]":
            depth -= 1
        if c == "," and depth == 0:
            pair = _parse_keyval(current.strip())
            if pair != None:
                result[pair[0]] = pair[1]
            current = ""
        else:
            current += c
    if current.strip() != "":
        pair = _parse_keyval(current.strip())
        if pair != None:
            result[pair[0]] = pair[1]

    return result


def _parse_keyval(s):
    # Parse "key": value
    idx = s.find(":")
    if idx == -1:
        return None
    key = s[:idx].strip().strip('"')
    val_str = s[idx+1:].strip()
    # Handle strings and dicts
    if val_str.startswith('"') and val_str.endswith('"'):
        val = val_str[1:-1]
    elif val_str.startswith("{"):
        val = _parse_dict(val_str)
    else:
        fail("unhandled JSON value type: " + val_str[:20])
    return (key, val)


def _parse_dict(s):
    # Parse JSON dict with known keys
    if not s.startswith("{") or not s.endswith("}"):
        fail("invalid dict")
    s = s[1:-1].strip()
    result = {}
    depth = 0
    current = ""
    for i in range(len(s)):
        c = s[i]
        if c in "{[":
            depth += 1
        elif c in "}]":
            depth -= 1
        if c == "," and depth == 0:
            pair = _parse_keyval(current.strip())
            if pair != None:
                result[pair[0]] = pair[1]
            current = ""
        else:
            current += c
    if current.strip() != "":
        pair = _parse_keyval(current.strip())
        if pair != None:
            result[pair[0]] = pair[1]
    return result
