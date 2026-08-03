# checkmk.by_ssh — translated read-only Starlark check module

def _parse_ssh_token(args, i, n):
    """Return (value, next_index) for the argument at index i, or (None, i+1)."""
    if i + 1 < n:
        return args[i + 1], i + 2
    return None, i + 1

def _parse_args(args):
    """Split an ssh command line (list of tokens) into a settings dict."""
    settings = {
        "hostname": None,
        "port": None,
        "ip_version": None,
        "timeout": None,
        "logname": None,
        "identity": None,
        "accept_new_host_keys": False,
        "command": None,
    }
    i = 0
    n = len(args)
    while i < n:
        token = args[i]
        if token == "-H":
            val, i = _parse_ssh_token(args, i, n)
            settings["hostname"] = val
        elif token == "-p":
            val, i = _parse_ssh_token(args, i, n)
            settings["port"] = val
        elif token == "-4":
            settings["ip_version"] = "ipv4"
            i += 1
        elif token == "-6":
            settings["ip_version"] = "ipv6"
            i += 1
        elif token == "-t":
            val, i = _parse_ssh_token(args, i, n)
            settings["timeout"] = val
        elif token == "-l":
            val, i = _parse_ssh_token(args, i, n)
            settings["logname"] = val
        elif token == "-i":
            val, i = _parse_ssh_token(args, i, n)
            settings["identity"] = val
        elif token == "-C":
            val, i = _parse_ssh_token(args, i, n)
            settings["command"] = val
        elif token == "-o":
            val, i = _parse_ssh_token(args, i, n)
            if val != None and "StrictHostKeyChecking=accept-new" in val:
                settings["accept_new_host_keys"] = True
        else:
            i += 1
    return settings

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["ssh", "-V"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "no items", "data": {"discovery": []}}

        command = params.get("command", "")
        hostname = params.get("hostname", "")
        port = params.get("port", None)
        ip_version = params.get("ip_version", None)
        timeout = params.get("timeout", None)
        logname = params.get("logname", None)
        identity = params.get("identity", None)
        accept_new_host_keys = params.get("accept_new_host_keys", False)

        item = command
        if hostname:
            item = hostname + " " + command
        entry = {
            "item": item,
            "params": {
                "command": command,
                "hostname": hostname,
                "port": port,
                "ip_version": ip_version,
                "timeout": timeout,
                "logname": logname,
                "identity": identity,
                "accept_new_host_keys": accept_new_host_keys,
            },
            "metrics": ["state"],
        }
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [entry]}}

    # CHECK MODE
    probe = ctx.run(["ssh", "-V"], mutates=False)
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "ssh binary not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "the ssh command is not installed"},
        }

    command = params.get("command", "")
    hostname = params.get("hostname", "")
    port = params.get("port", None)
    ip_version = params.get("ip_version", None)
    timeout = params.get("timeout", None)
    logname = params.get("logname", None)
    identity = params.get("identity", None)
    accept_new_host_keys = params.get("accept_new_host_keys", False)

    args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
    if hostname:
        args += ["-H", hostname]
    args += ["-C", command]
    if port != None:
        args += ["-p", str(port)]
    if ip_version == "ipv4":
        args.append("-4")
    elif ip_version == "ipv6":
        args.append("-6")
    if accept_new_host_keys:
        args += ["-o", "StrictHostKeyChecking=accept-new"]
    if timeout != None:
        args += ["-t", str(timeout)]
    if logname != None:
        args += ["-l", logname]
    if identity != None:
        args += ["-i", identity]

    res = ctx.run(["ssh"] + args, mutates=False)
    if res.rc == 0:
        state = "OK"
        msg = "ssh check succeeded"
        metrics = {"state": 0}
    elif res.rc == 1:
        state = "CRIT"
        msg = "ssh check failed: " + (res.stderr or res.stdout)
        metrics = {"state": 2}
    else:
        state = "UNKNOWN"
        msg = "ssh check error: " + (res.stderr or res.stdout)
        metrics = {"state": 3}

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": res.stderr or res.stdout},
    }