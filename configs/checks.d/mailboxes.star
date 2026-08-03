# Checkmk check: checkmk.mailboxes (server_side_calls active check)
# Translated to read-only Starlark for the yolo-man agent.

def _parse_perfdata(line):
    metrics = {}
    rest = line.split("|", 1)
    if len(rest) == 2:
        perf = rest[1].strip()
        for pair in perf.split():
            kv = pair.split("=", 1)
            if len(kv) == 2:
                val = kv[1]
                metrics[kv[0]] = float(val) if _is_number(val) else 0
    return metrics


def _is_number(s):
    if not s:
        return False
    if s.startswith("-"):
        return _is_number(s[1:])
    parts = s.split(".", 1)
    if len(parts) == 2:
        return parts[0].isdigit() and parts[1].isdigit()
    return s.isdigit()


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["which", "check_mailboxes"], mutates=False)
        tool_present = res.rc == 0
        if not tool_present:
            res_spool = ctx.run(["ls", "/var/mail", "/var/spool/mail"], mutates=False)
            spool_present = res_spool.rc == 0 and len(res_spool.stdout.strip()) > 0
            if not spool_present:
                return {"changed": False, "msg": "no local mail checking tool or spool found",
                        "data": {"discovery": []}}
        metrics = ["mail_count", "age_oldest"]
        fetch_protocol = params.get("fetch_protocol", "IMAP")
        host_labels = {}
        if fetch_protocol == "GRAPHAPI":
            host_labels = {"cmk/mailboxes": "graphapi"}
        elif fetch_protocol in ["IMAP", "POP3", "EWS"]:
            host_labels = {"cmk/mailboxes": fetch_protocol.lower()}
        return {"changed": False, "msg": "discovered 1 mailbox service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": metrics}],
                         "host_labels": host_labels}}

    item = params.get("item", "")

    res = ctx.run(["which", "check_mailboxes"], mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "check_mailboxes tool not installed; cannot check mailboxes",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    age_warn = params.get("age_warn")
    age_crit = params.get("age_crit")
    count_warn = params.get("count_warn")
    count_crit = params.get("count_crit")
    age_newest_warn = params.get("age_newest_warn")
    age_newest_crit = params.get("age_newest_crit")

    fetch_protocol = params.get("fetch_protocol", "IMAP")
    mailbox = params.get("mailbox", "/var/mail")
    tls = params.get("tls", True)
    disable_tls = params.get("disable_tls", False)

    args = ["check_mailboxes"]
    args += ["--fetch-protocol=" + str(fetch_protocol)]
    args += ["--fetch-server=localhost"]
    if tls:
        args.append("--fetch-tls")
    if not disable_tls:
        args.append("--fetch-tls")
    port = params.get("port")
    if port != None:
        args.append("--fetch-port=" + str(port))
    args += ["--mailbox=" + str(mailbox)]

    if age_warn != None and age_crit != None:
        args.append("--warn-age-oldest=" + str(int(age_warn)))
        args.append("--crit-age-oldest=" + str(int(age_crit)))
    if age_newest_warn != None and age_newest_crit != None:
        args.append("--warn-age-newest=" + str(int(age_newest_warn)))
        args.append("--crit-age-newest=" + str(int(age_newest_crit)))
    if count_warn != None and count_crit != None:
        args.append("--warn-count=" + str(int(count_warn)))
        args.append("--crit-count=" + str(int(count_crit)))

    out = ctx.run(args, mutates=False)
    if out.rc != 0:
        return {"changed": False,
                "msg": "check_mailboxes failed: " + out.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": out.stderr}}

    line = out.stdout.strip()
    metrics = {}
    state = "OK"
    msg = line
    if not line:
        return {"changed": False,
                "msg": "check_mailboxes returned no output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = line.split(":", 1)
    if len(parts) == 2:
        tag = parts[0].strip().upper()
        if tag == "OK":
            state = "OK"
        elif tag == "WARN":
            state = "WARN"
        elif tag == "CRIT":
            state = "CRIT"
        msg = parts[1].strip()
        metrics = _parse_perfdata(line)
    else:
        metrics = _parse_perfdata(line)

    if "age_oldest" in metrics:
        age_o = metrics["age_oldest"]
        if age_crit != None and (age_o >= age_crit):
            state = "CRIT"
        elif age_warn != None and (age_o >= age_warn):
            if state != "CRIT":
                state = "WARN"
    if "mail_count" in metrics and count_crit != None and count_warn != None:
        c = metrics["mail_count"]
        if c >= count_crit:
            state = "CRIT"
        elif c >= count_warn:
            if state != "CRIT":
                state = "WARN"

    if not msg:
        msg = (str(metrics.get("mail_count", 0)) + " mails, age " + str(metrics.get("age_oldest", 0)) + "h")

    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": line}}