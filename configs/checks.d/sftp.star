def _run_sftp_check(ctx, params):
    """Run the SFTP active check and return (rc, stdout, stderr)."""
    host = params.get("host", "")
    user = params.get("user", "")
    secret = params.get("secret", "")

    if not host or not user or not secret:
        fail("host, user, and secret are required parameters")

    argv = ["sftp"]
    argv = argv + ["--host", host, "--user", user, "--secret-reference", secret]

    port = params.get("port", None)
    if port != None:
        argv = argv + ["--port", str(port)]

    timeout = params.get("timeout", None)
    if timeout != None:
        argv = argv + ["--timeout", str(timeout)]

    timestamp = params.get("timestamp", None)
    if timestamp != None:
        argv = argv + ["--get-timestamp", timestamp]

    put_op = params.get("put", None)
    if put_op != None:
        argv = argv + ["--put-local", put_op.get("local", ""), "--put-remote", put_op.get("remote", "")]

    get_op = params.get("get", None)
    if get_op != None:
        argv = argv + ["--get-local", get_op.get("local", ""), "--get-remote", get_op.get("remote", "")]

    look_for_keys = params.get("look_for_keys", False)
    if look_for_keys:
        argv = argv + ["--look-for-keys"]

    res = ctx.run(argv, mutates=False)
    return res


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "")
        user = params.get("user", "")
        secret = params.get("secret", "")

        # This is an operator-configured active check. We only discover
        # if the required parameters are present.
        if not host or not user or not secret:
            return {"changed": False, "msg": "no SFTP check configured",
                    "data": {"discovery": []}}

        description = params.get("description", None)
        item = description if description != None else ("SFTP " + host)

        discovery = [{"item": item, "params": {}, "metrics": ["status"]}]
        return {"changed": False, "msg": "discovered 1 SFTP service",
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = _run_sftp_check(ctx, params)

    if res.rc == 0:
        state = "OK"
        # Try to extract a meaningful message from stdout
        stdout = res.stdout.strip()
        if stdout:
            msg = stdout
        else:
            host = params.get("host", "")
            msg = "SFTP check for %s succeeded" % host
    else:
        state = "CRIT"
        stderr = res.stderr.strip()
        stdout = res.stdout.strip()
        host = params.get("host", "")
        if stderr:
            msg = "SFTP check for %s failed (rc=%d): %s" % (host, res.rc, stderr)
        elif stdout:
            msg = "SFTP check for %s failed (rc=%d): %s" % (host, res.rc, stdout)
        else:
            msg = "SFTP check for %s failed with exit code %d" % (host, res.rc)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"status": res.rc}, "details": res.stdout + "\n" + res.stderr}}