def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {
                        "total": (60, 65),
                        "active": (60, 65),
                        "inactive": (10, 15),
                    },
                    "metrics": ["total", "active", "inactive"],
                }
            ]},
        }

    # --- probe for the real thing ---
    # The Checkmk agent plugin reads the <<<citrix_sessions>>> section, which is
    # produced by a Citrix-specific agent (over the network). There is no on-host
    # Citrix daemon on this host. Probe for the product binary/socket as the
    # source plugin would; absence means the service does not apply here.
    probe = ctx.run(["ctx", "is-citrix-present"], mutates=False)
    # rc 127 => not installed / not present
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "Citrix sessions: no Citrix environment found on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # --- gather the same data the agent section would provide ---
    # The agent section reports: sessions <n>, active_sessions <n>, inactive_sessions <n>
    # We read the equivalent on-host source. Since this is an agent-based check that
    # depends on a Citrix-specific agent, attempt the configured data path.
    out = probe.stdout.strip()
    session = {}
    if out:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) > 1:
                session.setdefault(parts[0], int(parts[1]))

    if not session:
        return {
            "changed": False,
            "msg": "Could not collect session information. Please check the agent configuration.",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    warn_total, crit_total = params.get("total", (60, 65))
    warn_active, crit_active = params.get("active", (60, 65))
    warn_inactive, crit_inactive = params.get("inactive", (10, 15))

    details = []
    metrics = {}
    worst = "OK"
    levels = {
        "sessions": (warn_total, crit_total),
        "active_sessions": (warn_active, crit_active),
        "inactive_sessions": (warn_inactive, crit_inactive),
    }
    labels = {
        "sessions": "total",
        "active_sessions": "active",
        "inactive_sessions": "inactive",
    }

    for key, what in [
        ("sessions", "total"),
        ("active_sessions", "active"),
        ("inactive_sessions", "inactive"),
    ]:
        val = session.get(key)
        if val == 0:
            continue
        w, c = levels[key]
        if val >= c:
            st = "CRIT"
        elif val >= w:
            st = "WARN"
        else:
            st = "OK"
        metrics[what] = val
        details.append("%s: %d (warn=%d, crit=%d) -> %s" % (what, val, w, c, st))
        if st == "CRIT":
            worst = "CRIT"
        elif st == "WARN" and worst != "CRIT":
            worst = "WARN"

    if not metrics:
        return {
            "changed": False,
            "msg": "No session metrics collected.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    msg = " | ".join(details)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": worst,
            "metrics": metrics,
            "details": "\n".join(details),
        },
    }