def main(ctx, params):
    host = params["host"]
    state = params["state"]
    backend = params.get("backend")
    weight = params.get("weight")
    socket_path = params.get("socket", "/var/run/haproxy.sock")
    shutdown_sessions = params.get("shutdown_sessions", False)
    fail_on_not_found = params.get("fail_on_not_found", False)
    agent = params.get("agent", False)
    health = params.get("health", False)
    wait = params.get("wait", False)
    wait_retries = params.get("wait_retries", 25)
    wait_interval = params.get("wait_interval", 5)
    drain_mode = params.get("drain", False)

    # Verify socket file exists
    if not ctx.file_exists(socket_path):
        fail("HAProxy socket file not found: " + socket_path)

    # Auto-detect backends if none specified
    if backend == None:
        show_stat_res = ctx.run(["echo", "show stat"], ok_codes=[0])
        if show_stat_res.rc != 0:
            fail("failed to list backends")
        output = show_stat_res.stdout.strip().lstrip("# ")
        lines = output.split("\n")
        if len(lines) == 0 or len(lines[0].strip()) == 0:
            fail("no backend data returned from 'show stat'")
        # Parse CSV-like output manually
        pxnames = []
        for line in lines[1:]:
            fields = line.split(",")
            if len(fields) >= 2 and fields[1] == "BACKEND":
                pxnames.append(fields[0])
        if len(pxnames) == 0:
            fail("no backends found")
        backends = pxnames
    else:
        backends = [backend]

    def get_server_state(pxname, svname):
        # Use nc to query haproxy
        cmd = ["sh", "-c", "echo 'show stat' | nc -U " + socket_path + " 2>/dev/null"]
        res = ctx.run(cmd, ok_codes=[0])
        if res.rc != 0:
            fail("failed to query haproxy: " + res.stderr)
        lines = res.stdout.strip().lstrip("# ").split("\n")
        if len(lines) == 0 or len(lines[0].strip()) == 0:
            return None
        for line in lines[1:]:
            parts = line.split(",")
            if len(parts) >= 11 and parts[1] == svname and (pxname == None or parts[0] == pxname):
                return {"status": parts[2], "weight": parts[3], "scur": parts[7]}
        return None

    def execute_haproxy_cmd(cmd):
        # Use echo and nc to send commands
        full_cmd = "echo '" + cmd + "' | nc -U " + socket_path
        res = ctx.run(["sh", "-c", full_cmd], ok_codes=[0])
        return res

    # Determine desired final status
    wait_status = ""
    if state == "enabled":
        wait_status = "UP"
    elif state == "disabled":
        wait_status = "MAINT"
    else:  # drain
        wait_status = "DRAIN"

    # Perform state change on each backend
    changed = False
    state_before = []
    state_after = []

    for backend_name in backends:
        # Record initial state
        state_before.append(get_server_state(backend_name, host))

        # Build command string
        cmd_parts = ["get weight " + backend_name + "/" + host]
        if state == "enabled":
            cmd_parts.append("enable server " + backend_name + "/" + host)
            if agent:
                cmd_parts.append("enable agent " + backend_name + "/" + host)
            if health:
                cmd_parts.append("enable health " + backend_name + "/" + host)
            if weight != None:
                cmd_parts.append("set weight " + backend_name + "/" + host + " " + weight)
        elif state == "disabled":
            cmd_parts.append("disable server " + backend_name + "/" + host)
            if agent:
                cmd_parts.append("disable agent " + backend_name + "/" + host)
            if health:
                cmd_parts.append("disable health " + backend_name + "/" + host)
            if shutdown_sessions:
                cmd_parts.append("shutdown sessions server " + backend_name + "/" + host)
        else:  # drain
            cmd_parts.append("set server " + backend_name + "/" + host + " state drain")

        cmd_str = "; ".join(cmd_parts)

        # Execute command
        res = execute_haproxy_cmd(cmd_str)
        if res.rc != 0:
            fail("haproxy command failed: " + res.stderr)

        # Record final state
        state_after.append(get_server_state(backend_name, host))

        # Check if state changed
        if state_before[-1] != state_after[-1]:
            changed = True

    # Wait for status if requested
    if wait:
        for i in range(wait_retries):
            all_ok = True
            for backend_name in backends:
                current = get_server_state(backend_name, host)
                if current == None:
                    fail("server " + host + " not found in backend " + backend_name)
                status = current["status"]
                if not (wait_status in status):
                    all_ok = False
                    break
                # For drain, ensure scur == 0 (no active sessions)
                if state == "drain" and current["scur"] != "0":
                    all_ok = False
                    break
            if all_ok:
                break
            if i < wait_retries - 1:
                # Sleep using a shell command since there's no native sleep in ctx
                ctx.run(["sh", "-c", "sleep " + str(wait_interval)], ok_codes=[0])

    return {
        "changed": changed,
        "msg": "haproxy state changed for " + host,
        "data": {
            "state_before": state_before,
            "state_after": state_after
        }
    }
