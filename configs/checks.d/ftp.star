def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "FTP active check has no discovery; configured per check",
            "data": {"discovery": []},
        }

    port = params.get("port", None)
    response_time = params.get("response_time", None)
    timeout = params.get("timeout", None)
    refuse_state = params.get("refuse_state", None)
    send_string = params.get("send_string", None)
    expect = params.get("expect", [])
    ssl = params.get("ssl", False)
    cert_days = params.get("cert_days", None)

    # Determine the service item string (mirrors check_ftp_get_item)
    if port != None and port != 21:
        item = "FTP Port " + str(port)
    else:
        item = "FTP"

    # The host to connect to
    host = params.get("host", "localhost")

    # If SSL is requested, require the openssl tool for cert validation
    if ssl and cert_days != None:
        probe = ctx.run(["which", "openssl"], mutates=False)
        if probe.rc != 0:
            return {
                "changed": False,
                "msg": "openssl binary not found; cannot perform SSL FTP check",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    # Build the command arguments mirroring generate_ftp_command
    args = ["-H", host]

    if port != None:
        args += ["-p", str(port)]

    if response_time != None:
        warn_ms, crit_ms = response_time
        args += ["-w", "%f" % (warn_ms / 1000.0)]
        args += ["-c", "%f" % (crit_ms / 1000.0)]

    if timeout != None:
        args += ["-t", str(timeout)]

    if refuse_state != None:
        args += ["-r", refuse_state]

    if send_string != None:
        args += ["-s", send_string]

    if expect != None:
        for s in expect:
            args += ["-e", s]

    if ssl:
        args.append("--ssl")

    if cert_days != None:
        cd_warn, cd_crit = cert_days
        args += ["-D", str(cd_warn), str(cd_crit)]

    # Probe for the monitored service — is the FTP client tool available?
    ftpprobe = ctx.run(["which", "ftp"], mutates=False)
    if ftpprobe.rc != 0:
        return {
            "changed": False,
            "msg": "ftp client not found on host; cannot perform FTP check",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Run the actual FTP check command (read-only connection test)
    check = ctx.run(["ftp"] + args, mutates=False)

    if check.rc != 0:
        rc = check.rc
        stderr = check.stderr.strip() if check.stderr != None else ""
        return {
            "changed": False,
            "msg": "FTP check failed (rc=%d): %s" % (rc, stderr),
            "data": {"state": "CRIT", "metrics": {}, "details": stderr},
        }

    stdout = check.stdout.strip() if check.stdout != None else ""

    # Parse response time from output if response_time thresholds were set
    metrics = {}
    state = "OK"
    details = stdout

    if response_time != None and stdout != None:
        # Look for a floating point response time in the output
        # Common formats: "response time: 0.123 seconds" or a bare number
        tokens = stdout.split()
        rt = None
        for i in range(len(tokens)):
            t = tokens[i]
            # Try to parse a number from the token
            cleaned = t
            if cleaned.endswith("s") or cleaned.endswith("sec"):
                cleaned = cleaned[:-1] if cleaned.endswith("s") else cleaned[:-3]
            # Strip common non-numeric prefixes
            parts = cleaned.split(":")
            if len(parts) > 1:
                cleaned = parts[-1].strip()
            if cleaned.replace(".", "", 1).replace("-", "", 1).isdigit():
                rt = float(cleaned)
                break
        if rt != None:
            warn_ms, crit_ms = response_time
            rt_ms = rt * 1000.0
            metrics["response_time_ms"] = rt_ms
            if rt_ms >= crit_ms:
                state = "CRIT"
            elif rt_ms >= warn_ms:
                state = "WARN"

    return {
        "changed": False,
        "msg": item + " " + state + ": " + stdout,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }