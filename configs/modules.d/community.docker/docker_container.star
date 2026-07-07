def main(ctx, params):
    # This module is a thin wrapper around docker CLI commands.
    # Due to complexity and extensive options (including network, volume,
    # device, and healthcheck configurations), only the core state
    # management (present/absent/started/stopped) with minimal required
    # functionality is implemented.
    #
    # Unsupported features: comparisons, default behavior variants,
    # healthcheck, mounts, networks, device requests, env_file, etc.
    # These cause fail() when used.
    #
    # Idempotency relies on docker inspect + name lookup.

    name = params.get("name")
    state = params.get("state", "started")
    image = params.get("image")
    command = params.get("command")
    privileged = params.get("privileged")
    detach = params.get("detach")
    tty = params.get("tty")
    interactive = params.get("interactive")
    restart = params.get("restart")
    ports = params.get("published_ports") or params.get("ports")
    volumes = params.get("volumes")
    env = params.get("env")
    network = params.get("networks") if "networks" in params else None
    auto_remove = params.get("auto_remove")
    memory = params.get("memory")
    cpus = params.get("cpus")
    hostname = params.get("hostname")
    user = params.get("user")
    working_dir = params.get("working_dir")
    labels = params.get("labels")
    cap_add = params.get("capabilities")
    cap_drop = params.get("cap_drop")
    devices = params.get("devices")

    # Unsupported options
    unsupported = [
        "comparisons", "container_default_behavior", "healthcheck",
        "mounts", "networks_cli_compatible", "env_file", "device_requests",
        "device_read_bps", "device_write_bps", "device_read_iops",
        "device_write_iops", "dns_opts", "dns_servers", "dns_search_domains",
        "domainname", "etc_hosts", "exposed_ports", "exposed", "expose",
        "force_kill", "groups", "ipc_mode", "keep_volumes", "kill_signal",
        "kernel_memory", "links", "log_driver", "log_options", "log_opt",
        "mac_address", "memory_reservation", "memory_swap", "memory_swappiness",
        "network_mode", "oom_killer", "oom_score_adj", "output_logs",
        "pid_mode", "pids_limit", "platform", "publish_all_ports", "pull",
        "purge_networks", "read_only", "removal_wait_timeout", "restart_policy",
        "restart_retries", "runtime", "shm_size", "security_opts", "stop_signal",
        "stop_timeout", "storage_opts", "tmpfs", "ulimits", "sysctls", "uts",
        "default_host_ip", "image_comparison", "image_label_mismatch",
        "image_name_mismatch", "ignore_image", "cleanup", "detach", "init",
        "interactive", "paused", "privileged", "read_only", "tty", "blkio_weight",
        "cpu_period", "cpu_quota", "cpu_shares", "cpuset_cpus", "cpuset_mems"
    ]

    for opt in unsupported:
        if opt in params and params[opt] != None:
            fail("unsupported option: " + opt)

    # Basic validations
    if not name:
        fail("missing required parameter: name")

    # Helper: inspect container by name
    def inspect_container():
        res = ctx.run(["docker", "inspect", name])
        if res.rc == 0:
            return res.stdout  # JSON array, assume first element
        if "No such object" in res.stderr or "No such container" in res.stderr:
            return None
        fail("failed to inspect container " + name + ": " + res.stderr)

    # Helper: run container
    def run_container_command():
        args = ["docker", "run", "--name", name, "--rm"]
        if detach == True:
            args.append("-d")
        if privileged == True:
            args.append("--privileged")
        if tty == True:
            args.append("-t")
        if interactive == True:
            args.append("-i")
        if auto_remove == True:
            args.append("--rm")
        if restart == True:
            args.append("--restart=on-failure")
        if ports:
            for p in ports:
                args.extend(["-p", p])
        if volumes:
            for v in volumes:
                args.extend(["-v", v])
        if env:
            for k, v in env.items():
                args.extend(["-e", k + "=" + str(v)])
        if memory:
            args.extend(["-m", memory])
        if cpus:
            args.extend(["--cpus", str(cpus)])
        if hostname:
            args.extend(["--hostname", hostname])
        if user:
            args.extend(["-u", user])
        if working_dir:
            args.extend(["-w", working_dir])
        if labels:
            for k, v in labels.items():
                args.extend(["--label", k + "=" + str(v)])
        if cap_add:
            for c in cap_add:
                args.extend(["--cap-add", c])
        if cap_drop:
            for c in cap_drop:
                args.extend(["--cap-drop", c])
        if devices:
            for d in devices:
                args.extend(["--device", d])
        if image == None:
            fail("image is required when creating container")
        args.append(image)
        if command:
            if type(command) == type([]):
                args.extend(command)
            else:
                args.append(str(command))
        return ctx.run(args, mutates=True)

    # State handling
    container = inspect_container()

    if state == "absent":
        if container == None:
            return {"changed": False, "msg": "container " + name + " does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove container " + name}
        stop_res = ctx.run(["docker", "stop", name])
        if stop_res.rc != 0 and "No such container" not in stop_res.stderr and "not found" not in stop_res.stderr:
            fail("failed to stop container " + name + ": " + stop_res.stderr)
        rm_res = ctx.run(["docker", "rm", name])
        if rm_res.rc != 0:
            fail("failed to remove container " + name + ": " + rm_res.stderr)
        return {"changed": True, "msg": "removed container " + name}

    # present, started, stopped
    if container == None:
        if ctx.check_mode:
            return {"changed": True, "msg": "would create container " + name}
        res = run_container_command()
        if res.skipped:
            return {"changed": True, "msg": "would create container " + name}
        if res.rc != 0:
            fail("failed to create container " + name + ": " + res.stderr)
        # Container was created (detach=true) or ran successfully (detach=false)
        return {"changed": True, "msg": "created container " + name}

    # Container exists
    # Parse inspect output to determine state
    res_inspect = ctx.run(["docker", "inspect", name])
    if res_inspect.rc != 0:
        fail("failed to inspect container " + name)

    # Manual JSON parsing (simple heuristics for boolean state)
    stdout = res_inspect.stdout
    if len(stdout) == 0 or stdout[0] != '[':
        fail("failed to parse inspect output for " + name)
    running = '"Running": true' in stdout

    if state in ["started", "present"]:
        if state == "started" and not running:
            if ctx.check_mode:
                return {"changed": True, "msg": "would start container " + name}
            start_res = ctx.run(["docker", "start", name])
            if start_res.skipped:
                return {"changed": True, "msg": "would start container " + name}
            if start_res.rc != 0:
                fail("failed to start container " + name + ": " + start_res.stderr)
            return {"changed": True, "msg": "started container " + name}
        if state == "started" and running:
            return {"changed": False, "msg": "container " + name + " already running"}
        if state == "present" and running:
            return {"changed": False, "msg": "container " + name + " already exists and running"}
        if state == "present" and not running:
            if ctx.check_mode:
                return {"changed": True, "msg": "would start container " + name}
            start_res = ctx.run(["docker", "start", name])
            if start_res.skipped:
                return {"changed": True, "msg": "would start container " + name}
            if start_res.rc != 0:
                fail("failed to start container " + name + ": " + start_res.stderr)
            return {"changed": True, "msg": "started container " + name}

    if state == "stopped":
        if not running:
            return {"changed": False, "msg": "container " + name + " already stopped"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would stop container " + name}
        stop_res = ctx.run(["docker", "stop", name])
        if stop_res.skipped:
            return {"changed": True, "msg": "would stop container " + name}
        if stop_res.rc != 0:
            fail("failed to stop container " + name + ": " + stop_res.stderr)
        return {"changed": True, "msg": "stopped container " + name}

    fail("unsupported state: " + state)
