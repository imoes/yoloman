def main(ctx, params):
    host_labels = {}
    # This check monitors Oracle database jobs, data collected by Checkmk's
    # mk_oracle agent plugin from a running Oracle instance. The on-host source
    # is an Oracle DB, not a local /proc or /sys file. We have no special-agent
    # transport here, so probe for the Oracle client tooling the agent plugin
    # relies on to establish whether anything to check is present.
    has_oracle = False
    for tool in ["sqlplus", "sql", "rman", "srvctl", "lsnrctl"]:
        res = ctx.run([tool, "-v"], mutates=False)
        if res.rc != 127:
            has_oracle = True
            break

    if params.get("_discover"):
        if not has_oracle:
            # No Oracle client/tools -> nothing this check can monitor.
            return {
                "changed": False,
                "msg": "discovered 0 oracle jobs",
                "data": {
                    "discovery": [],
                    "host_labels": host_labels,
                },
            }
        # Without a running Oracle instance and the mk_oracle agent section we
        # cannot enumerate jobs. Report absence rather than fabricating items.
        return {
            "changed": False,
            "msg": "discovered 0 oracle jobs",
            "data": {
                "discovery": [],
                "host_labels": host_labels,
            },
        }

    item = params.get("item", "")
    if not has_oracle:
        return {
            "changed": False,
            "msg": "no oracle instance found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Oracle client tooling not found on host",
            },
        }

    # No oracle_jobs section data is available (it requires the Checkmk
    # mk_oracle agent plugin querying a live Oracle DB), so we cannot grade
    # the named job.
    return {
        "changed": False,
        "msg": "no oracle job data available for " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "oracle_jobs section not provided by any on-host source",
        },
    }