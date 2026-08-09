def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "superuser")
    ssh_key = params.get("ssh_key", "/root/.ssh/id_rsa")

    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["messages"]},
            ]},
        }

    res = ctx.run([
        "ssh",
        "-i", ssh_key,
        "-o", "StrictHostKeyChecking=no",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        user + "@" + host,
        "svcinfo lseventlog -nohdr -delim : -filtervalue fixed=no",
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Failed to query IBM SVC eventlog: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    messagecount = 0
    last_err = ""

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        fields = line.split(":")
        if len(fields) < 11:
            continue
        messagecount += 1
        last_err = ":".join(fields[10:])

    if messagecount > 0:
        return {
            "changed": False,
            "msg": "%d messages not expired and not yet fixed found in event log, last was: %s" % (messagecount, last_err),
            "data": {"state": "WARN", "metrics": {"messages": messagecount}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "No messages not expired and not yet fixed found in event log",
        "data": {"state": "OK", "metrics": {"messages": 0}, "details": ""},
    }