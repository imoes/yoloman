def main(ctx, params):
    command = params.get("command")
    if command == "slave":
        command = "replica"

    # Common redis connection params
    login_host = params.get("login_host", "localhost")
    login_port = params.get("login_port", 6379)
    login_user = params.get("login_user")
    login_password = params.get("login_password")
    tls = params.get("tls", False)
    validate_certs = params.get("validate_certs", True)
    ca_certs = params.get("ca_certs")

    # Build redis-cli command base
    base_argv = ["redis-cli", "-h", str(login_host), "-p", str(login_port)]
    if login_user != None:
        base_argv.extend(["-u", "redis://" + login_user + ":" + str(login_password) + "@" + login_host + ":" + str(login_port)])
    elif login_password != None:
        base_argv.extend(["-a", login_password])
    if tls:
        base_argv.append("--tls")

    # Replica command
    if command == "replica":
        master_host = params.get("master_host")
        master_port = params.get("master_port")
        replica_mode = params.get("replica_mode", "replica")
        if replica_mode == "slave":
            replica_mode = "replica"

        if replica_mode == "replica":
            if master_host == None:
                fail("In replica mode master host must be provided")
            if master_port == None:
                fail("In replica mode master port must be provided")
            # Check current state
            res = ctx.run(base_argv + ["INFO", "replication"], mutates=False)
            if res.rc != 0:
                fail("unable to connect to database: " + res.stderr)
            role_line = None
            master_host_line = None
            master_port_line = None
            for line in res.stdout.split("\n"):
                if line.startswith("role:"):
                    role_line = line.split(":", 1)[1].strip()
                elif line.startswith("master_host:"):
                    master_host_line = line.split(":", 1)[1].strip()
                elif line.startswith("master_port:"):
                    master_port_line = line.split(":", 1)[1].strip()
            if role_line == "master":
                if replica_mode == "master":
                    return {"changed": False, "msg": "already in master mode"}
                else:
                    pass  # Need to change
            elif role_line == "slave":
                if replica_mode == "replica":
                    if master_host_line == master_host and master_port_line == str(master_port):
                        return {"changed": False,
                                "msg": "already replica of %s:%d" % (master_host, master_port)}
                # else: need to change to master
            # Perform change
            if ctx.check_mode:
                return {"changed": True, "msg": "would set replica mode to " + replica_mode}
            if replica_mode == "replica":
                cmd_argv = base_argv + ["SLAVEOF", str(master_host), str(master_port)]
                res = ctx.run(cmd_argv, mutates=True)
                if res.rc != 0:
                    fail("Unable to set replica mode: " + res.stderr)
                return {"changed": True, "msg": "set replica mode to master %s:%d" % (master_host, master_port)}
            else:
                res = ctx.run(base_argv + ["SLAVEOF", "NO", "ONE"], mutates=True)
                if res.rc != 0:
                    fail("Unable to set master mode: " + res.stderr)
                return {"changed": True, "msg": "set replica mode to master"}

        # Replica mode master
        if replica_mode == "master":
            res = ctx.run(base_argv + ["INFO", "replication"], mutates=False)
            if res.rc != 0:
                fail("unable to connect to database: " + res.stderr)
            role_line = None
            for line in res.stdout.split("\n"):
                if line.startswith("role:"):
                    role_line = line.split(":", 1)[1].strip()
            if role_line == "master":
                return {"changed": False, "msg": "already in master mode"}
            if ctx.check_mode:
                return {"changed": True, "msg": "would set replica mode to master"}
            res = ctx.run(base_argv + ["SLAVEOF", "NO", "ONE"], mutates=True)
            if res.rc != 0:
                fail("Unable to set master mode: " + res.stderr)
            return {"changed": True, "msg": "set replica mode to master"}

    # Flush command
    if command == "flush":
        flush_mode = params.get("flush_mode", "all")
        db = params.get("db")

        if flush_mode == "db":
            if db == None:
                fail("In db mode the db number must be provided")
            if ctx.check_mode:
                return {"changed": True, "msg": "would flush db %d" % db}
            cmd_argv = base_argv + ["FLUSHDB"]
            res = ctx.run(cmd_argv, mutates=True)
            if res.rc != 0:
                fail("Unable to flush db %d: " % db + res.stderr)
            return {"changed": True, "msg": "flushed db %d" % db}

        # flush_mode == "all"
        if ctx.check_mode:
            return {"changed": True, "msg": "would flush all databases"}
        cmd_argv = base_argv + ["FLUSHALL"]
        res = ctx.run(cmd_argv, mutates=True)
        if res.rc != 0:
            fail("Unable to flush all databases: " + res.stderr)
        return {"changed": True, "msg": "flushed all databases"}

    # Config command
    if command == "config":
        name = params.get("name")
        value = params.get("value")
        if name == None:
            fail("name is required for config command")
        if value == None:
            fail("value is required for config command")

        # Read current value
        res = ctx.run(base_argv + ["CONFIG", "GET", name], mutates=False)
        if res.rc != 0:
            fail("unable to read config: " + res.stderr)
        old_value = ""
        lines = res.stdout.split("\n")
        if len(lines) >= 2:
            for i in range(len(lines)):
                if lines[i] == name and i + 1 < len(lines):
                    old_value = lines[i + 1]
                    break
        changed = old_value != str(value)

        if ctx.check_mode or not changed:
            return {"changed": changed, "msg": "config %s already %s" % (name, str(value))}

        # Set new value
        res = ctx.run(base_argv + ["CONFIG", "SET", name, str(value)], mutates=True)
        if res.rc != 0:
            fail("unable to set config: " + res.stderr)
        return {"changed": True, "msg": "config %s updated to %s" % (name, str(value))}

    fail("A valid command must be provided")
