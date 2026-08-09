def main(ctx, params):
    # Mandatory parameters
    project_src = params["project_src"]
    state = params.get("state", "present")

    # Optional parameters with defaults
    dependencies = params.get("dependencies", True)
    pull = params.get("pull", "policy")
    build = params.get("build", "policy")
    recreate = params.get("recreate", "auto")
    remove_images = params.get("remove_images")
    remove_volumes = params.get("remove_volumes", False)
    remove_orphans = params.get("remove_orphans", False)
    timeout = params.get("timeout")
    services = params.get("services") or []
    scale = params.get("scale") or {}
    project_name = params.get("project_name")
    files = params.get("files") or []

    # Build base arguments list
    base_args = ["docker", "compose"]
    if project_name:
        base_args.extend(["--project-name", project_name])
    for f in files:
        base_args.extend(["-f", f])
    base_args.append("--project-directory")
    base_args.append(project_src)

    # Helper: run compose command
    def run_compose(args_list, dry_run=False, mutates=False):
        args = args_list[:]
        if dry_run:
            args.append("--dry-run")
        res = ctx.run(args, mutates=mutates)
        return res.rc, res.stdout, res.stderr

    # Helper: list containers raw
    def list_containers_raw():
        cmd = base_args + ["ps", "--format", "json"]
        rc, stdout, stderr = run_compose(cmd, mutates=False)
        if rc != 0:
            return []
        # Parse JSON line by line (simple approach for Starlark)
        containers = []
        for line in stdout.splitlines():
            line = line.strip()
            if line == "":
                continue
            # Minimal JSON parsing: assume known structure
            item = {}
            # Split by comma then extract key-value pairs
            parts = line.split(", ")
            for part in parts:
                if ":" in part:
                    kv = part.split(":", 1)
                    if len(kv) == 2:
                        k = kv[0].strip(" \"")
                        v = kv[1].strip(" \"")
                        item[k] = v
            if item.get("Name") != None:
                containers.append(item)
        return containers

    # Helper: parse events (simplified)
    def parse_events(stderr):
        events = []
        for line in stderr.splitlines():
            line = line.strip()
            if line.startswith("Creating") or line.startswith("Starting") or \
               line.startswith("Stopping") or line.startswith("Removing") or \
               line.startswith("Pulling") or line.startswith("Building"):
                parts = line.split(" ", 1)
                events.append({"status": parts[0] if len(parts) > 0 else "unknown", "what": "unknown"})
        return events

    # State logic
    if state == "present":
        args = base_args + ["up", "--detach", "--no-color", "--quiet-pull"]
        if pull != "policy":
            args.extend(["--pull", pull])
        if remove_orphans:
            args.append("--remove-orphans")
        if recreate == "always":
            args.append("--force-recreate")
        if recreate == "never":
            args.append("--no-recreate")
        if not dependencies:
            args.append("--no-deps")
        if timeout != None:
            args.extend(["--timeout", str(timeout)])
        if build == "always":
            args.append("--build")
        elif build == "never":
            args.append("--no-build")
        for svc, cnt in sorted(scale.items()):
            args.extend(["--scale", "%s=%d" % (svc, cnt)])
        for svc in services:
            args.append(svc)

        # Check current state
        containers = list_containers_raw()
        running = [c for c in containers if c.get("State") == "running"]
        if len(running) > 0 and recreate != "always":
            return {"changed": False, "msg": "Services already running", "containers": containers}

        if ctx.check_mode:
            return {"changed": True, "msg": "would run docker compose up"}

        rc, stdout, stderr = run_compose(args, dry_run=False, mutates=True)
        events = parse_events(stderr)
        if rc != 0:
            fail("docker compose up failed: " + stderr)
        result = {"containers": list_containers_raw(), "images": []}
        if len(events) > 0:
            result["actions"] = []
            for e in events:
                result["actions"].append({"what": e.get("what", "unknown"), "status": e.get("status", "unknown")})
        else:
            result["actions"] = []
        return {"changed": True, "msg": "services up", "data": result}

    elif state == "stopped":
        # Ensure containers are created (no-start up)
        args_up = base_args + ["up", "--no-start", "--no-color", "--quiet-pull"]
        for svc in services:
            args_up.append(svc)
        if ctx.check_mode:
            return {"changed": True, "msg": "would ensure stopped containers"}
        rc1, stdout1, stderr1 = run_compose(args_up, dry_run=False, mutates=True)
        if rc1 != 0:
            fail("docker compose up (no-start) failed: " + stderr1)

        # Check if already stopped
        containers = list_containers_raw()
        running = [c for c in containers if c.get("State") in ("running", "created")]
        if len(running) == 0:
            return {"changed": False, "msg": "services already stopped", "containers": containers}

        # Stop
        args_stop = base_args + ["stop"]
        if timeout != None:
            args_stop.extend(["--timeout", str(timeout)])
        for svc in services:
            args_stop.append(svc)

        rc2, stdout2, stderr2 = run_compose(args_stop, dry_run=False, mutates=True)
        if rc2 != 0:
            fail("docker compose stop failed: " + stderr2)

        result = {"containers": list_containers_raw(), "images": []}
        return {"changed": True, "msg": "services stopped", "data": result}

    elif state == "restarted":
        args_restart = base_args + ["restart"]
        if not dependencies:
            args_restart.append("--no-deps")
        if timeout != None:
            args_restart.extend(["--timeout", str(timeout)])
        for svc in services:
            args_restart.append(svc)

        if ctx.check_mode:
            return {"changed": True, "msg": "would restart services"}

        rc, stdout, stderr = run_compose(args_restart, dry_run=False, mutates=True)
        if rc != 0:
            fail("docker compose restart failed: " + stderr)

        result = {"containers": list_containers_raw(), "images": []}
        return {"changed": True, "msg": "services restarted", "data": result}

    elif state == "absent":
        args_down = base_args + ["down"]
        if remove_orphans:
            args_down.append("--remove-orphans")
        if remove_images:
            args_down.extend(["--rmi", remove_images])
        if remove_volumes:
            args_down.append("--volumes")
        if timeout != None:
            args_down.extend(["--timeout", str(timeout)])
        for svc in services:
            args_down.append(svc)

        # Check if containers exist
        containers = list_containers_raw()
        if len(containers) == 0:
            return {"changed": False, "msg": "no services to remove", "containers": []}

        if ctx.check_mode:
            return {"changed": True, "msg": "would run docker compose down"}

        rc, stdout, stderr = run_compose(args_down, dry_run=False, mutates=True)
        if rc != 0:
            fail("docker compose down failed: " + stderr)

        result = {"containers": [], "images": []}
        return {"changed": True, "msg": "services removed", "data": result}

    else:
        fail("unsupported state: " + state)
