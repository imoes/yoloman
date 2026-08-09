def main(ctx, params):
    hosts = params["hosts"]
    name = params["name"]
    value = params.get("value")
    op = params.get("op")
    state = params.get("state")
    timeout = params.get("timeout", 300)
    recursive = params.get("recursive", False)
    auth_scheme = params.get("auth_scheme", "digest")
    auth_credential = params.get("auth_credential")
    use_tls = params.get("use_tls", False)

    # Mutual exclusion check
    if op != None and state != None:
        fail("Please choose an operation (op) or a state, but not both.")
    if op == None and state == None:
        fail("Please define an operation (op) or a state.")

    # Build zk CLI command
    cmd = ["zkCli.sh", "-server", hosts]
    if use_tls:
        fail("TLS/SSL support requires the kazoo Python library, which is not available in Starlark runtime")

    # Authentication
    if auth_credential != None:
        # Only digest and sasl supported; format same for both per docs
        cmd.extend(["-A", auth_scheme + ":" + auth_credential])

    # Operation dispatch
    if op == "list":
        res = ctx.run(cmd + ["ls", name])
        if res.rc != 0:
            fail("failed to list znodes: " + res.stderr)
        # Parse children list (zkCli.sh output starts with [ and ends with ])
        output = res.stdout.strip()
        if output.startswith("[") and output.endswith("]"):
            items_str = output[1:-1].strip()
            if items_str == "":
                children = []
            else:
                children = [x.strip().strip('"').strip("'") for x in items_str.split(",")]
        else:
            children = output.splitlines()
        return {"changed": False, "count": len(children), "items": children, "msg": "Retrieved znodes in path.", "znode": name}

    if op == "get":
        # Get value and stat (simplified: only value available via CLI)
        res = ctx.run(cmd + ["get", name])
        if res.rc != 0:
            fail("failed to get znode: " + res.stderr)
        output = res.stdout.strip()
        # First line is the value (or empty line if no value)
        lines = output.splitlines()
        value_out = ""
        if len(lines) > 0 and lines[0] != "":
            value_out = lines[0]
        # Stat block usually follows; skip parsing stat in Starlark due to complexity and lack of standard format
        return {"changed": False, "msg": "The node was retrieved.", "value": value_out, "znode": name}

    if op == "wait":
        # Polling until node exists (no native wait in zkCli.sh CLI)
        start = ctx.facts().get("uptime_seconds", 0) if "uptime_seconds" in ctx.facts() else 0
        end_time = start + timeout
        interval = 5
        while start < end_time:
            res = ctx.run(cmd + ["ls", name])
            if res.rc == 0:
                # Node exists if ls succeeded
                return {"changed": False, "msg": "The node appeared before the configured timeout.", "timeout": timeout, "znode": name}
            # Sleep interval using simple countdown
            ctx.run(["sleep", str(interval)])
            # Approximate elapsed time (not exact but sufficient)
            start += interval
        fail("The node did not appear before the operation timed out.")

    # State operations
    if state == "absent":
        # Check existence first
        res = ctx.run(cmd + ["ls", name])
        exists = res.rc == 0
        if not exists:
            return {"changed": False, "msg": "The znode does not exist."}
        # Delete
        del_cmd = cmd + ["rmr", name] if recursive else cmd + ["delete", name]
        res = ctx.run(del_cmd)
        if res.rc != 0:
            fail("failed to delete znode: " + res.stderr)
        return {"changed": True, "msg": "The znode was deleted."}

    if state == "present":
        # Check existence
        res = ctx.run(cmd + ["ls", name])
        exists = res.rc == 0
        if exists:
            # Get current value
            get_res = ctx.run(cmd + ["get", name])
            if get_res.rc != 0:
                fail("failed to get current value: " + get_res.stderr)
            current = get_res.stdout.strip()
            if current == value:
                return {"changed": False, "msg": "No changes were necessary.", "znode": name, "value": current}
            # Update
            update_res = ctx.run(cmd + ["set", name, value])
            if update_res.rc != 0:
                fail("failed to update znode: " + update_res.stderr)
            return {"changed": True, "msg": "Updated the znode value.", "znode": name, "value": value}
        else:
            # Create
            create_res = ctx.run(cmd + ["create", name, value])
            if create_res.rc != 0:
                fail("failed to create znode: " + create_res.stderr)
            return {"changed": True, "msg": "Created a new znode.", "znode": name, "value": value}

    fail("Unsupported operation or state: op=" + str(op) + ", state=" + str(state))
