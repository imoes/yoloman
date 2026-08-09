def main(ctx, params):
    key = params["key"]
    increment_int = params.get("increment_int")
    increment_float = params.get("increment_float")
    login_host = params.get("login_host", "localhost")
    login_port = params.get("login_port", 6379)
    login_user = params.get("login_user")
    login_password = params.get("login_password")
    tls = params.get("tls", True)
    ca_certs = params.get("ca_certs")
    validate_certs = params.get("validate_certs", True)

    # Build redis-cli command
    argv = ["redis-cli"]
    if login_host != "localhost":
        argv += ["-h", str(login_host)]
    argv += ["-p", str(login_port)]
    if login_user != None:
        password = login_password if login_password != None else ""
        argv += ["-u", "redis://" + login_user + ":" + password + "@" + login_host + ":" + str(login_port)]
    elif login_password != None:
        argv += ["-a", login_password]
    if not tls:
        argv += ["--no-tls"]
    if not validate_certs:
        argv += ["--insecure"]
    if ca_certs != None:
        argv += ["--cacert", ca_certs]

    # Determine increment value and operation
    increment = 1
    if increment_float != None:
        increment = increment_float
        op = "incrbyfloat"
    elif increment_int != None:
        increment = increment_int
        op = "incrby"
    else:
        op = "incr"

    # Handle check_mode: simulate by reading current value and computing result
    if ctx.check_mode:
        res = ctx.run(argv + ["GET", key])
        # Handle NOKEY case (key missing)
        if res.rc != 0 and (res.stderr.find("NOKEY") != -1 or res.stderr.find("not exist") != -1):
            current = 0.0
        elif res.rc != 0:
            fail("Failed to get key '" + key + "': " + res.stderr)
        else:
            current = float(res.stdout.strip())

        new_val = current + float(increment)
        return {"changed": True, "msg": "Incremented key: " + key + " by " + str(increment) + " to " + str(new_val), "value": new_val}

    # Real execution: perform increment
    if op == "incr":
        res = ctx.run(argv + ["INCR", key], mutates=True)
    elif op == "incrby":
        res = ctx.run(argv + ["INCRBY", key, str(increment)], mutates=True)
    else:  # incrbyfloat
        res = ctx.run(argv + ["INCRBYFLOAT", key, str(increment)], mutates=True)

    if res.rc != 0:
        fail("Failed to increment key '" + key + "': " + res.stderr)

    value = float(res.stdout.strip())

    if op == "incr":
        msg = "Incremented key: " + key + " to " + str(value)
    else:
        msg = "Incremented key: " + key + " by " + str(increment) + " to " + str(value)

    return {"changed": True, "msg": msg, "value": value}
