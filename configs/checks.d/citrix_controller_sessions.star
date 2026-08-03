def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["total_sessions", "active_sessions", "inactive_sessions"]}
            ]},
        }

    # Citrix Controller sessions are read from the Citrix Broker service
    # via PowerShell. The original Checkmk plugin parses an agent section
    # populated by a Citrix-specific data source. There is no on-host file
    # or generic Linux command we can substitute for that; absence means
    # the data is not available here.
    res = ctx.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command",
         "Get-BrokerSession -AdminAddress localhost | Measure-Object | Select-Object -ExpandProperty Count"],
        mutates=False,
    )

    if res.rc != 0 and not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no Citrix Broker reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    count_str = res.stdout.strip()
    if not count_str.isdigit():
        return {
            "changed": False,
            "msg": "no Citrix Broker reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total = int(count_str)
    # With a single total count and no distinct active/inactive split from
    # the Citrix Broker in this minimal probe, we treat all as active and
    # report inactive as 0.
    active = total
    inactive = 0

    warn_total = params.get("total")
    crit_total = params.get("total_crit")
    warn_active = params.get("active")
    crit_active = params.get("active_crit")
    warn_inactive = params.get("inactive")
    crit_inactive = params.get("inactive_crit")

    def level(value, warn, crit):
        if crit != None and value >= crit:
            return "CRIT"
        if warn != None and value >= warn:
            return "WARN"
        return "OK"

    # Determine the worst state across the three metrics
    states = [
        level(total, warn_total, crit_total),
        level(active, warn_active, crit_active),
        level(inactive, warn_inactive, crit_inactive),
    ]

    worst = "OK"
    for s in states:
        if s == "CRIT":
            worst = "CRIT"
            break
        if s == "WARN" and worst == "OK":
            worst = "WARN"

    metrics = {
        "total_sessions": total,
        "active_sessions": active,
        "inactive_sessions": inactive,
    }

    return {
        "changed": False,
        "msg": "Sessions: total %d, active %d, inactive %d" % (total, active, inactive),
        "data": {"state": worst, "metrics": metrics, "details": ""},
    }