def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("hostname") or ""
    if not host:
        return {"changed": False, "msg": "UNKNOWN", "data": {"state": "UNKNOWN", "metrics": {}, "details": "hostname is required"}}

    command = params.get("command") or ""
    if not command:
        return {"changed": False, "msg": "UNKNOWN", "data": {"state": "UNKNOWN", "metrics": {}, "details": "command is required"}}

    port = int(params.get("port") or 22)
    timeout_s = int(params.get("timeout_s") or 10)
    logname = params.get("logname") or ""
    identity = params.get("identity") or ""
    accept_new = params.get("accept_new_host_keys") or False
    ip_version = params.get("ip_version") or ""

    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=%d" % timeout_s, "-p", "%d" % port]

    if accept_new:
        argv += ["-o", "StrictHostKeyChecking=accept-new"]

    if ip_version == "ipv4":
        argv.append("-4")
    elif ip_version == "ipv6":
        argv.append("-6")

    if logname:
        argv += ["-l", logname]

    if identity:
        argv += ["-i", identity]

    argv.append(host)
    argv.append(command)

    result = ctx.run(argv, ok_codes=[0, 1, 2, 3, 255])
    rc = result.rc
    stdout = (result.stdout or "").strip()
    stderr = (result.stderr or "").strip()

    if rc == 255:
        details = stderr if stderr else "SSH connection failed (rc=255)"
        return {"changed": False, "msg": "CRIT", "data": {"state": "CRIT", "metrics": {}, "details": details}}

    if rc == 0:
        state = "OK"
    elif rc == 1:
        state = "WARN"
    elif rc == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    details = stdout if stdout else (stderr if stderr else "Exit code %d" % rc)

    return {"changed": False, "msg": state, "data": {"state": state, "metrics": {"exit_code": rc}, "details": details}}
