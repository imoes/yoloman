def main(ctx, params):
    if params.get("_discover"):
        # This is a single-service check with no per-item breakdown.
        # Discovery always yields exactly one service.
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"levels": (20, 30)},
                        "metrics": ["logins"],
                    }
                ]
            },
        }

    item = params.get("item", "")
    levels = params.get("levels", (20, 30))
    warn = levels[0] if len(levels) >= 1 else 20
    crit = levels[1] if len(levels) >= 2 else 30

    # Read the logins count from /var/run/utmp via `who` — this is the
    # same data the Checkmk agent plugin surfaces under the `logins` section.
    res = ctx.run(["who", "-q"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "unable to determine login count",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": res.stderr,
            },
        }

    # `who -q` prints a list of logged-in users followed by a blank line
    # and a summary line like "# users=N".
    lines = res.stdout.splitlines()
    users = []
    user_count = 0
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("# users="):
            rest = stripped[len("# users="):]
            if rest.isdigit():
                user_count = int(rest)
        else:
            parts = stripped.split()
            if len(parts) > 0:
                users.append(parts[0])

    # Fall back to counting parsed user tokens if the summary line was absent.
    section = user_count if user_count > 0 else len(users)

    # Grade levels (upper-level check): WARN if >= warn, CRIT if >= crit.
    state = "OK"
    if section >= crit:
        state = "CRIT"
    elif section >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "%s On system: %d" % (state, section),
        "data": {
            "state": state,
            "metrics": {"logins": section},
            "details": "",
        },
    }