def main(ctx, params):
    token = params["token"]
    msg = params["msg"]
    api = params.get("api", "data.logentries.com")
    port = params.get("port", 80)

    # Validate port type
    if type(port) != "int":
        fail("port must be an integer")

    # Construct message
    message = token + " " + msg + "\n"

    # Resolve hostname to IP (basic DNS lookup)
    # We cannot use socket in Starlark, so use ctx.run with nslookup or similar
    # Prefer getent or host for portability across distros
    res = ctx.run(["getent", "hosts", api], mutates=False)
    if res.rc != 0:
        # fallback to host command if getent fails
        res = ctx.run(["host", "-t", "A", api], mutates=False)
        if res.rc != 0:
            fail("failed to resolve " + api + ": " + res.stderr)
        # Parse output like "api.logentries.com has address 1.2.3.4"
        lines = res.stdout.splitlines()
        ip = None
        for line in lines:
            parts = line.split()
            if "address" in parts:
                ip = parts[parts.index("address") + 1]
                break
        if ip == None:
            fail("could not parse IP address for " + api)
    else:
        # getent outputs: "1.2.3.4 hostname alias" — extract first field
        ip = res.stdout.split()[0]

    # Build raw TCP message and send
    # Starlark cannot directly open sockets; use nc (netcat) if available
    # This is the only portable way in sandboxed envs
    # Ensure we use -w for timeout
    nc_cmd = ["nc", "-w", "10", ip, str(port)]

    if ctx.check_mode:
        # In check mode, we just validate the command would be valid and return changed=True
        return {"changed": True, "msg": "would send message to logentries"}

    send_res = ctx.run(nc_cmd + ["-q", "0"], mutates=True)
    # Note: Some nc versions may not support -q; alternative is to use echo | nc
    if send_res.rc != 0:
        # Try with echo pipe fallback
        pipe_res = ctx.run(["sh", "-c", "echo '" + message.replace("'", "'\\''") + "' | nc -w 10 " + ip + " " + str(port)], mutates=True)
        if pipe_res.rc != 0:
            fail("failed to send message to logentries: " + pipe_res.stderr)

    return {"changed": True, "msg": "message sent to logentries"}
