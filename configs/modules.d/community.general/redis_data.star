def main(ctx, params):
    key = params["key"]
    value = params.get("value")
    expiration = params.get("expiration")
    existing = params.get("existing", False)
    non_existing = params.get("non_existing", False)
    keep_ttl = params.get("keep_ttl", False)
    state = params.get("state", "present")
    host = params.get("login_host", "localhost")
    port = params.get("login_port", 6379)
    user = params.get("login_user")
    password = params.get("login_password")
    tls = params.get("tls", True)
    ca_certs = params.get("ca_certs")
    validate_certs = params.get("validate_certs", True)

    # Validate required parameters
    if state == "present" and value == None:
        fail("value is required when state is present")
    if existing and non_existing:
        fail("non_existing and existing are mutually exclusive")
    if keep_ttl and expiration != None:
        fail("keep_ttl and expiration are mutually exclusive")

    # Build redis-cli command arguments
    conn_args = []
    if tls:
        conn_args.append("-h")
        conn_args.append(host)
        conn_args.append("-p")
        conn_args.append(str(port))
        conn_args.append("--tls")
        if not validate_certs:
            conn_args.append("--insecure")
        if ca_certs != None:
            conn_args.append("--cacert")
            conn_args.append(ca_certs)
    else:
        conn_args.append("-h")
        conn_args.append(host)
        conn_args.append("-p")
        conn_args.append(str(port))

    if user != None:
        conn_args.append("-u")
        conn_args.append(user + ":" + (password if password != None else ""))
    elif password != None:
        conn_args.append("-a")
        conn_args.append(password)

    # Get current value (probe)
    get_cmd = conn_args + ["GET", key]
    res = ctx.run(get_cmd)
    if res.rc != 0:
        fail("failed to get key '" + key + "': " + res.stderr)
    old_value = res.stdout.strip() if res.stdout.strip() != "" else None

    changed = False
    msg = ""

    if state == "absent":
        if old_value == None:
            msg = "Key: " + key + " not present"
            return {"changed": False, "msg": msg}

        if ctx.check_mode:
            msg = "Deleted key: " + key
            return {"changed": True, "msg": msg}

        del_cmd = conn_args + ["DEL", key]
        res = ctx.run(del_cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete key: " + key}
        if res.rc != 0:
            fail("failed to delete key '" + key + "': " + res.stderr)

        deleted_count = int(res.stdout.strip()) if res.stdout.strip() != "" else 0
        if deleted_count == 0:
            msg = "Key: " + key + " not present"
            return {"changed": False, "msg": msg}

        msg = "Deleted key: " + key
        return {"changed": True, "msg": msg, "old_value": old_value}

    # state == "present"
    # Check conditions for setting
    should_set = False
    if non_existing:
        if old_value == None:
            should_set = True
    elif existing:
        if old_value != None:
            should_set = True
    else:
        should_set = True

    # Check if value already matches (no change needed)
    if should_set and old_value == value and not keep_ttl and expiration == None:
        msg = "Key " + key + " already has desired value"
        return {"changed": False, "msg": msg, "value": value}

    # Build SET command args
    set_args = conn_args + ["SET", key, value]

    if keep_ttl:
        set_args.append("KEEPTTL")
    if expiration != None:
        set_args.append("PX")
        set_args.append(str(expiration))
    if non_existing:
        set_args.append("NX")
    if existing:
        set_args.append("XX")

    if ctx.check_mode:
        msg = "Set key: " + key
        return {"changed": True, "msg": msg, "value": value, "old_value": old_value}

    res = ctx.run(set_args, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would set key: " + key, "value": value, "old_value": old_value}

    if res.rc != 0:
        err_msg = "failed to set key '" + key + "': " + res.stderr
        if res.stdout.strip() != "":
            err_msg += " (stdout: " + res.stdout.strip() + ")"
        fail(err_msg)

    # Redis SET returns "OK" on success, or None for NX/XX conditions
    if res.stdout.strip() != "OK":
        if non_existing:
            msg = "Could not set key: " + key + ". Key already present."
        else:
            msg = "Could not set key: " + key + ". Key not present."
        fail(msg)

    return {"changed": True, "msg": "Set key: " + key, "value": value, "old_value": old_value}
