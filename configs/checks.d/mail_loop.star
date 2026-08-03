# ===== Checkmk check: cmk/mail_loop =====
# Translated to a read-only Starlark check module for the yolo-man agent.

DEFAULT_WARN = 30.0
DEFAULT_CRIT = 60.0


def _build_args(params, ctx):
    """Build the argument vector for the mail-loop probe from params."""
    args = []

    fetch = params.get("fetch", {})
    fetch_protocol = fetch.get("protocol", "IMAP")
    args.append("--fetch-protocol=" + str(fetch_protocol))

    fetch_server = fetch.get("server", "")
    if fetch_server:
        args.append("--fetch-server=" + str(fetch_server))

    fetch_port = fetch.get("port", 0)
    if fetch_port:
        args.append("--fetch-port=" + str(fetch_port))

    disable_tls = fetch.get("disable_tls", False)
    if disable_tls:
        args.append("--fetch-disable-tls")

    disable_cert = fetch.get("disable_cert_validation", False)
    if disable_cert:
        args.append("--fetch-disable-cert-validation")

    auth = fetch.get("auth", {})
    auth_method = auth.get("method", "")
    if auth_method == "basic":
        args.append("--fetch-username=" + str(auth.get("username", "")))
        args.append("--fetch-password-reference=" + str(auth.get("password", "")))
    elif auth_method == "oauth2":
        args.append("--fetch-client-id=" + str(auth.get("client_id", "")))
        args.append("--fetch-client-secret-reference=" + str(auth.get("client_secret", "")))
        args.append("--fetch-tenant-id=" + str(auth.get("tenant_id", "")))

    connect_timeout = params.get("connect_timeout", 0.0)
    if connect_timeout:
        args.append("--connect-timeout=" + str(connect_timeout))

    send = params.get("send", {})
    send_protocol = send.get("protocol", "SMTP")
    args.append("--send-protocol=" + str(send_protocol))

    send_server = send.get("server", "")
    if send_server:
        args.append("--send-server=" + str(send_server))

    send_port = send.get("port", 0)
    if send_port:
        args.append("--send-port=" + str(send_port))

    send_tls = send.get("tls", False)
    if send_tls:
        args.append("--send-tls")

    send_disable_cert = send.get("disable_cert_validation", False)
    if send_disable_cert:
        args.append("--send-disable-cert-validation")

    send_auth = send.get("auth", {})
    send_auth_method = send_auth.get("method", "")
    if send_auth_method == "basic":
        args.append("--send-username=" + str(send_auth.get("username", "")))
        args.append("--send-password-reference=" + str(send_auth.get("password", "")))
    elif send_auth_method == "oauth2":
        args.append("--send-client-id=" + str(send_auth.get("client_id", "")))
        args.append("--send-client-secret-reference=" + str(send_auth.get("client_secret", "")))
        args.append("--send-tenant-id=" + str(send_auth.get("tenant_id", "")))

    send_email = send.get("email_address", "")
    if send_email:
        args.append("--send-email-address=" + str(send_email))

    mail_from = params.get("mail_from", "")
    args.append("--mail-from=" + str(mail_from))

    mail_to = params.get("mail_to", "")
    args.append("--mail-to=" + str(mail_to))

    delete_messages = params.get("delete_messages", False)
    if delete_messages:
        args.append("--delete-messages")

    duration = params.get("duration", {})
    duration_type = duration.get("type", "no_levels")
    if duration_type == "fixed":
        levels = duration.get("levels", [DEFAULT_WARN, DEFAULT_CRIT])
        args.append("--warning=" + str(int(levels[0])))
        args.append("--critical=" + str(int(levels[1])))

    subject = params.get("subject", None)
    if subject != None:
        args.append("--subject=" + str(subject))

    return args


def _probe_mail_loop_binary(ctx):
    """Check whether the mail loop test tool is installed."""
    res = ctx.run(["check_mail_loop", "--help"], mutates=False)
    return res


def _parse_float(val):
    """Parse a float from string val, or return (0.0, False) if not parseable."""
    v = val.strip()
    if v.endswith("s"):
        v = v[:-1]
    if len(v) == 0:
        return (0.0, False)
    valid = True
    has_digit = False
    for ch in v:
        if ch == "-" or ch == "+":
            continue
        if ch.isdigit():
            has_digit = True
        elif ch == ".":
            has_digit = True
        else:
            valid = False
            break
    if valid and has_digit:
        return (float(v), True)
    return (0.0, False)


def main(ctx, params):
    if params.get("_discover"):
        probe = _probe_mail_loop_binary(ctx)
        if probe.rc == 127:
            return {
                "changed": False,
                "msg": "check_mail_loop tool not found",
                "data": {"discovery": []},
            }

        item = params.get("item", "")
        if not item:
            item = "default"

        warn = DEFAULT_WARN
        crit = DEFAULT_CRIT
        duration = params.get("duration", {})
        if duration.get("type", "no_levels") == "fixed":
            levels = duration.get("levels", [DEFAULT_WARN, DEFAULT_CRIT])
            warn = levels[0]
            crit = levels[1]

        return {
            "changed": False,
            "msg": "discovered 1 mail loop item",
            "data": {
                "discovery": [
                    {
                        "item": item,
                        "params": {
                            "warn": warn,
                            "crit": crit,
                        },
                        "metrics": ["duration"],
                    }
                ]
            },
        }

    item = params.get("item", "")
    if not item:
        item = "default"

    probe = _probe_mail_loop_binary(ctx)
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "check_mail_loop tool not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "The mail loop test tool (check_mail_loop) is not installed.",
            },
        }

    cmd_args = _build_args(params, ctx)
    hostname = ctx.facts().get("hostname", "host")
    full_cmd = ["check_mail_loop"] + cmd_args + ["--status-suffix=" + hostname + "-" + item]

    res = ctx.run(full_cmd, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "mail loop test failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "check_mail_loop exited with code " + str(res.rc) + ": " + res.stderr,
            },
        }

    stdout = res.stdout
    duration_seconds = 0.0
    found_duration = False

    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("duration="):
            val = stripped[len("duration="):]
            fs, ok = _parse_float(val)
            if ok:
                duration_seconds = fs
                found_duration = True

    if not found_duration:
        lines = stdout.strip().splitlines()
        if lines:
            last_line = lines[-1]
            parts = last_line.split()
            idx = 0
            while idx < len(parts):
                fs, ok = _parse_float(parts[idx])
                if ok:
                    duration_seconds = fs
                    found_duration = True
                    break
                idx = idx + 1

    if not found_duration:
        return {
            "changed": False,
            "msg": "could not parse duration from mail loop test output",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Raw output: " + stdout,
            },
        }

    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    duration_cfg = params.get("duration", {})
    if duration_cfg.get("type", "no_levels") == "fixed":
        levels = duration_cfg.get("levels", [DEFAULT_WARN, DEFAULT_CRIT])
        warn = levels[0]
        crit = levels[1]

    state = "OK"
    if duration_seconds >= crit:
        state = "CRIT"
    elif duration_seconds >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Mail loop duration: %fs" % duration_seconds,
        "data": {
            "state": state,
            "metrics": {"duration": duration_seconds},
            "details": stdout,
        },
    }