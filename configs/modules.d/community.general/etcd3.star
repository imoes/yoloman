def main(ctx, params):
    key = params["key"]
    value = params["value"]
    state = params["state"]
    host = params.get("host", "localhost")
    port = params.get("port", 2379)
    user = params.get("user")
    password = params.get("password")
    ca_cert = params.get("ca_cert")
    client_cert = params.get("client_cert")
    client_key = params.get("client_key")
    timeout = params.get("timeout")

    # Validate required combinations
    if client_cert != None and client_key == None:
        fail("client_key is required when client_cert is defined")
    if client_key != None and client_cert == None:
        fail("client_cert is required when client_key is defined")
    if user != None and password == None:
        fail("password is required when user is defined")
    if password != None and user == None:
        fail("user is required when password is defined")
    if (client_cert != None or client_key != None) and ca_cert == None:
        fail("ca_cert is required when client_cert and client_key are defined")

    # Build etcdctl command
    cmd = ["etcdctl", "--endpoints", host + ":" + str(port)]
    
    # Add TLS options
    if ca_cert != None:
        cmd += ["--cacert", ca_cert]
    if client_cert != None:
        cmd += ["--cert", client_cert]
    if client_key != None:
        cmd += ["--key", client_key]
    
    # Add authentication
    if user != None:
        cmd += ["--user", user + ":" + (password if password != None else "")]
    
    # Add timeout if specified
    if timeout != None:
        cmd += ["--dial-timeout", str(timeout)]

    # Probe current value
    get_cmd = cmd + ["get", key]
    res = ctx.run(get_cmd, mutates=False)
    if res.rc != 0:
        fail("failed to get key " + key + ": " + res.stderr)

    # Parse value from etcdctl output (returns raw key-value on separate lines)
    lines = res.stdout.strip().split("\n") if res.stdout.strip() != "" else []
    old_value = ""
    if len(lines) >= 2:
        old_value = lines[1]  # second line contains the value
    
    # Handle absent state
    if state == "absent":
        if old_value != "" or ctx.file_exists(key):  # key exists
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete " + key, "key": key, "old_value": old_value}
            delete_cmd = cmd + ["del", key]
            del_res = ctx.run(delete_cmd, mutates=True)
            if del_res.skipped:
                return {"changed": True, "msg": "would delete " + key, "key": key, "old_value": old_value}
            if del_res.rc != 0:
                fail("failed to delete key " + key + ": " + del_res.stderr)
            return {"changed": True, "msg": "deleted " + key, "key": key, "old_value": old_value}
        return {"changed": False, "msg": key + " already absent", "key": key, "old_value": old_value}
    
    # Handle present state
    if state == "present":
        if old_value == value:
            return {"changed": False, "msg": key + " already correct", "key": key, "old_value": old_value}
        if ctx.check_mode:
            return {"changed": True, "msg": "would update " + key, "key": key, "old_value": old_value}
        put_cmd = cmd + ["put", key, value]
        put_res = ctx.run(put_cmd, mutates=True)
        if put_res.skipped:
            return {"changed": True, "msg": "would update " + key, "key": key, "old_value": old_value}
        if put_res.rc != 0:
            fail("failed to put key " + key + ": " + put_res.stderr)
        return {"changed": True, "msg": "updated " + key, "key": key, "old_value": old_value}
    
    fail("unsupported state: " + state)
