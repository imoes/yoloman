def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: the qmail queue directory tree.
        # Absence of the product means no service, never a placeholder.
        if not ctx.file_exists("/var/qmail/queue"):
            return {"changed": False, "msg": "no qmail queue found", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"deferred": [10, 20]},
                        "metrics": ["queue"],
                    }
                ]
            },
        }

    # CHECK MODE — read the deferred queue length from the on-host qmail queue.
    # The Checkmk agent plugin reads the `qmail-qstat` output; we reproduce the
    # same data source. If qmail is not installed (rc==127) or the queue is
    # missing, the product is absent -> UNKNOWN, never OK.
    res = ctx.run(["/var/qmail/bin/qmail-qstat"], mutates=False)
    if not res.stdout or res.rc == 127:
        return {
            "changed": False,
            "msg": "no qmail installation found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    length = 0
    found = False
    for line in res.stdout.splitlines():
        # Lines look like: "Messages in queue but not yet preprocessed: 0"
        # or  "Messages in queue: 0" / "Messages in queue but not preprocessed: 1"
        # We want the total deferred count; qmail-qstat reports a single total.
        lower = line.lower()
        if lower.find("messages") != -1 and lower.find("queue") != -1:
            # extract the trailing integer
            parts = line.split()
            for token in reversed(parts):
                stripped = token.rstrip(",")
                if stripped.isdigit():
                    length = int(stripped)
                    found = True
                    break
            if found:
                break

    if not found:
        # Fallback: take the last integer found anywhere in the output.
        last_int = None
        for line in res.stdout.splitlines():
            for token in line.split():
                if token.isdigit():
                    last_int = int(token)
        if last_int == None:
            return {
                "changed": False,
                "msg": "could not parse qmail queue length",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        length = last_int

    # Threshold levels come from params; Checkmk default is (warn, crit) = (10, 20).
    levels = params.get("deferred", [10, 20])
    if len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = 10
        crit = 20

    if length >= crit:
        state = "CRIT"
    elif length >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Deferred mails: %d" % length,
        "data": {
            "state": state,
            "metrics": {"queue": length},
            "details": "Deferre`d mails in qmail queue: %d" % length,
        },
    }