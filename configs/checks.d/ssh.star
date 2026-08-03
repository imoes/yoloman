# Check: checkmk.ssh → translated to read-only Starlark check module
# Active check: probes SSH connectivity on a target host using check_ssh

def _parse_args(argv):
    """Parse check_ssh output arguments; we grade mostly on rc, but parse
    the textual output for version/protocol info to include in details."""
    return argv

def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        # An active check that targets a host: the "item" is the service
        # description itself. We probe for the check_ssh binary and whether
        # we have a host to check. The host comes from params or facts.
        host = params.get("host") or ctx.facts().get("address") or ctx.facts().get("hostname", "localhost")
        if not host:
            return {"changed": False, "msg": "no host to check SSH against",
                    "data": {"discovery": [], "host_labels": {}}}

        # Probe for the real thing: check_ssh binary
        probe = ctx.run(["check_ssh", "--help"], mutates=False)
        if probe.rc == 127:
            # check_ssh not installed — this check does not apply
            return {"changed": False, "msg": "check_ssh binary not found",
                    "data": {"discovery": [], "host_labels": {}}}

        # Single-service active check: one item, item = ""
        port = params.get("port", 22)
        desc = params.get("description", "")
        item = "SSH %s" % desc if desc else "SSH"
        return {"changed": False,
                "msg": "discovered SSH active check for %s:%s" % (host, port),
                "data": {"discovery": [
                    {"item": item,
                     "params": {
                         "host": host,
                         "port": port,
                         "timeout": params.get("timeout", 10),
                         "description": desc,
                         "remote_version": params.get("remote_version"),
                         "remote_protocol": params.get("remote_protocol"),
                     },
                     "metrics": ["ssh_reachable"],
                     "service_labels": {"port": str(port)},
                    }],
                    "host_labels": {"cmk/active_check": "ssh"}}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    host = params.get("host") or ctx.facts().get("address") or ctx.facts().get("hostname", "localhost")
    port = params.get("port", 22)
    timeout = params.get("timeout", 10)
    description = params.get("description", "")
    remote_version = params.get("remote_version")
    remote_protocol = params.get("remote_protocol")

    # Probe for the real thing first
    probe = ctx.run(["check_ssh", "--help"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "check_ssh binary not found",
                "data": {"state": "UNKNOWN",
                         "metrics": {},
                         "details": "The check_ssh binary is not installed on this host. Cannot verify SSH connectivity to %s." % host}}

    # Build the check_ssh command
    argv = ["check_ssh", "-H", host, "-t", str(timeout), "-p", str(port)]
    if remote_version != None:
        argv += ["-r", remote_version]
    if remote_protocol != None:
        argv += ["-P", str(remote_protocol)]

    res = ctx.run(argv, mutates=False)

    # check_ssh exit codes:
    #   0 = OK (SSH is reachable)
    #   1 = WARNING
    #   2 = CRITICAL
    #   3 = UNKNOWN
    rc = res.rc
    stdout = res.stdout
    stderr = res.stderr

    # Determine state from exit code
    if rc == 0:
        state = "OK"
        msg = "SSH %s:%s is reachable" % (host, port)
    elif rc == 1:
        state = "WARN"
        msg = "SSH %s:%s warning: %s" % (host, port, _strip_output(stdout, stderr))
    elif rc == 2:
        state = "CRIT"
        msg = "SSH %s:%s not reachable: %s" % (host, port, _strip_output(stdout, stderr))
    elif rc == 3:
        state = "UNKNOWN"
        msg = "SSH %s:%s unknown: %s" % (host, port, _strip_output(stdout, stderr))
    else:
        # Non-standard exit code
        state = "UNKNOWN"
        msg = "SSH check %s:%s failed (rc=%s): %s" % (host, port, rc, _strip_output(stdout, stderr))

    # Metric: 1 if reachable (OK), 0 otherwise
    reachable = 1 if rc == 0 else 0
    metrics = {"ssh_reachable": float(reachable)}
    details = stdout if stdout != "" else stderr

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": metrics,
                     "details": details}}


def _strip_output(stdout, stderr):
    """Return a cleaned single-line summary from check_ssh output."""
    out = stdout.strip() if stdout != "" else ""
    err = stderr.strip() if stderr != "" else ""
    if out != "":
        return out
    if err != "":
        return err
    return "no output"