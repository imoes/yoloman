def main(ctx, params):
    key = params["key"]
    host = params.get("login_host", "localhost")
    port = int(params.get("login_port", 6379))
    user = params.get("login_user")
    password = params.get("login_password")
    use_tls = bool(params.get("tls", True))
    validate_certs = bool(params.get("validate_certs", True))
    ca_certs = params.get("ca_certs")

    # Build redis-cli command
    argv = ["redis-cli"]
    if use_tls:
        argv.append("--tls")
        if not validate_certs:
            argv.append("--insecure")
        if ca_certs != None:
            argv.extend(["--cacert", ca_certs])
    if user != None:
        argv.extend(["-u", "redis://" + user + ":" + (password or "") + "@" + host + ":" + str(port)])
    else:
        argv.extend(["-h", host, "-p", str(port)])
        if password != None:
            argv.extend(["-a", password])
    argv.append("GET")
    argv.append(key)

    res = ctx.run(argv, mutates=False)
    if res.rc != 0:
        fail("failed to get key '" + key + "': " + res.stderr.strip())

    value = res.stdout.strip()
    if value == "" and not res.stdout == "":
        # redis-cli returns empty string for non-existent key when output is raw
        value = None

    if value == None or value == "(nil)":
        return {"changed": False, "exists": False, "msg": 'Key "' + key + '" does not exist in database'}
    else:
        return {"changed": False, "exists": True, "value": value, "msg": 'Got key "' + key + '"'}
