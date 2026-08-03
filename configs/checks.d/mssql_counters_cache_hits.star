def main(ctx, params):
    if params.get("_discover"):
        # This check monitors a Microsoft SQL Server instance via the Checkmk
        # mssql_counters agent section, which is populated by a special agent
        # talking to a remote SQL Server. There is no local SQL Server data
        # source available on this host without that agent. The honest
        # translation therefore reports absence: discovery yields nothing.
        return {
            "changed": False,
            "msg": "no local mssql_counters data source available",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    # No on-host data source for remote SQL Server counters.
    return {
        "changed": False,
        "msg": "no mssql_counters section available (SQL Server special agent not configured)",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "The mssql_counters_cache_hits check requires a remote SQL Server special agent; no local data source is available.",
        },
    }