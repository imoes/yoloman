def main(ctx, params):
    # Only basic support: rely on docker-compose CLI
    # Fail if unsupported options are used
    definition = params.get("definition")
    project_src = params.get("project_src")
    if definition == None and project_src == None:
        fail("Either 'project_src' or 'definition' must be provided")

    if definition != None and project_src != None:
        fail("Cannot specify both 'project_src' and 'definition'")

    # Basic validation of mutually exclusive combinations
    if params.get("files") != None and definition != None:
        fail("'files' is mutually exclusive with 'definition'")
    if params.get("env_file") != None and params.get("definition") != None and params.get("project_src") == None:
        fail("With inline 'definition', 'project_src' is required to resolve relative paths like 'env_file'")

    # Map core boolean flags
    state = params.get("state", "present")
    if state not in ["present", "absent"]:
        fail("Unsupported state: " + state)

    # Map recreate strategy
    recreate = params.get("recreate", "smart")
    if recreate not in ["always", "never", "smart"]:
        fail("Unsupported recreate value: " + recreate)

    # Build base CLI
    base_argv = ["docker-compose"]
    if project_src != None:
        base_argv.extend(["-f", project_src + "/docker-compose.yml"])
    else:
        # For definition mode, write a temp file and use it
        # Since no os/path support, use /tmp and a fixed file name
        temp_path = "/tmp/docker-compose.yml"
        content = yaml_dump(definition)
        if not ctx.check_mode:
            ctx.file_write(temp_path, content, "0644")
        base_argv.extend(["-f", temp_path])

    # Handle project name
    if params.get("project_name") != None:
        base_argv.extend(["-p", params["project_name"]])
    elif project_src != None:
        # derive project name from basename of project_src
        parts = project_src.split("/")
        if len(parts) > 0 and parts[-1] != "":
            base_argv.extend(["-p", parts[-1]])
        else:
            fail("Could not determine project name from project_src")
    else:
        fail("project_name is required when using inline definition")

    # Optional file overrides
    if params.get("files") != None:
        base_argv = ["docker-compose"]  # reset for multiple -f
        if project_src != None:
            for f in params["files"]:
                base_argv.extend(["-f", project_src + "/" + f])
        else:
            for f in params["files"]:
                base_argv.extend(["-f", f])
        if params.get("project_name") != None:
            base_argv.extend(["-p", params["project_name"]])
        elif project_src != None:
            parts = project_src.split("/")
            if len(parts) > 0 and parts[-1] != "":
                base_argv.extend(["-p", parts[-1]])
            else:
                fail("Could not determine project name from project_src")
        else:
            fail("project_name is required when using inline definition")

    # Profile option
    if params.get("profiles") != None:
        for p in params["profiles"]:
            base_argv.extend(["--profile", p])

    # env-file
    if params.get("env_file") != None:
        ef = params["env_file"]
        # relative to project_src if available
        if project_src != None:
            ef = project_src + "/" + ef
        base_argv.extend(["--env-file", ef])

    # Hostname check
    hostname_check = params.get("hostname_check", False)
    if hostname_check:
        base_argv.append("--tlscert")
        base_argv.append("")
        base_argv.append("--tlskey")
        base_argv.append("")
    else:
        base_argv.append("--skip-hostname-check")

    # Build common command suffix
    suffix = []
    if params.get("remove_orphans", False):
        suffix.append("--remove-orphans")
    if params.get("dependencies", True):
        suffix.append("--dependencies")
    else:
        suffix.append("--no-deps")

    # State handling
    if state == "absent":
        down_argv = base_argv + ["down"]
        if params.get("remove_images") != None:
            if params["remove_images"] == "all":
                down_argv.append("--rmi all")
            elif params["remove_images"] == "local":
                down_argv.append("--rmi local")
            else:
                fail("Unsupported remove_images value: " + params["remove_images"])
        if params.get("remove_volumes", False):
            down_argv.append("-v")
        res = ctx.run(down_argv, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would run docker-compose down"}
        if res.rc != 0:
            fail("docker-compose down failed: " + res.stderr)
        return {"changed": True, "msg": "ran docker-compose down"}

    # state == present
    if params.get("restarted", False) and params.get("stopped", False):
        fail("Cannot use both 'restarted' and 'stopped'")

    # Base up command
    up_argv = base_argv + ["up", "-d"]
    if recreate == "never":
        up_argv.append("--no-recreate")
    elif recreate == "always":
        up_argv.append("--force-recreate")

    if params.get("build", False):
        up_argv.append("--build")

    if params.get("pull", False):
        up_argv.append("--pull")

    if params.get("nocache", False):
        up_argv.append("--no-cache")

    # Services selection
    if params.get("services") != None and len(params["services"]) > 0:
        up_argv.extend(params["services"])

    # Scale
    if params.get("scale") != None:
        for svc, cnt in params["scale"].items():
            up_argv.extend(["--scale", svc + "=" + str(cnt)])

    # Extra flags
    up_argv.extend(suffix)

    if params.get("stopped", False):
        # Use stop after up; no direct docker-compose flag in v1 for this
        # We simulate by doing up, then stop
        res = ctx.run(up_argv, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would run docker-compose up then stop"}
        if res.rc != 0:
            fail("docker-compose up failed: " + res.stderr)

        stop_argv = base_argv + ["stop"]
        if params.get("services") != None and len(params["services"]) > 0:
            stop_argv.extend(params["services"])
        stop_argv.extend(suffix)
        sres = ctx.run(stop_argv, mutates=True)
        if sres.skipped:
            return {"changed": True, "msg": "would run docker-compose stop"}
        if sres.rc != 0:
            fail("docker-compose stop failed: " + sres.stderr)
        return {"changed": True, "msg": "ran docker-compose up then stop"}

    if params.get("restarted", False):
        # Run up, then restart
        res = ctx.run(up_argv, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would run docker-compose up then restart"}
        if res.rc != 0:
            fail("docker-compose up failed: " + res.stderr)

        restart_argv = base_argv + ["restart"]
        if params.get("services") != None and len(params["services"]) > 0:
            restart_argv.extend(params["services"])
        restart_argv.extend(suffix)
        rres = ctx.run(restart_argv, mutates=True)
        if rres.skipped:
            return {"changed": True, "msg": "would run docker-compose restart"}
        if rres.rc != 0:
            fail("docker-compose restart failed: " + rres.stderr)
        return {"changed": True, "msg": "ran docker-compose up then restart"}

    # Default present: run up
    res = ctx.run(up_argv, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would run docker-compose up -d"}
    if res.rc != 0:
        fail("docker-compose up failed: " + res.stderr)
    return {"changed": True, "msg": "ran docker-compose up -d"}


# Simple YAML dumper for inline definition to file
def yaml_dump(d):
    lines = []
    def visit(obj, indent):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if isinstance(v, (dict, list)) and v:
                    lines.append(" " * indent + str(k) + ":")
                    visit(v, indent + 2)
                else:
                    lines.append(" " * indent + str(k) + ": " + yaml_scalar(v))
        elif isinstance(obj, list):
            for item in obj:
                if isinstance(item, (dict, list)):
                    # multi-line list item
                    lines.append(" " * indent + "-")
                    visit(item, indent + 2)
                else:
                    lines.append(" " * indent + "- " + yaml_scalar(item))
        else:
            lines.append(" " * indent + yaml_scalar(obj))
    visit(d, 0)
    return "\n".join(lines) + "\n"


def yaml_scalar(v):
    if v == None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return str(v)
    if isinstance(v, str):
        # Basic quoting when needed
        if v == "" or " " in v or ":" in v or "#" in v or "\n" in v or v in ["true", "false", "null", "yes", "no"]:
            return '"' + v.replace("\\", "\\\\").replace("\"", "\\\"") + '"'
        return v
    return str(v)
