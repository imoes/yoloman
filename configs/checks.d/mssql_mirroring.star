# Checkmk check: mssql_mirroring — translated to a read-only Starlark check module.
# Data source: sys.database_mirroring (on database [master]) on a Microsoft SQL Server host.
# This translation runs on OUR agent, which does NOT have Checkmk installed.
# It therefore has no on-host source to read: the monitored data lives in a remote
# SQL Server instance (queried via a special agent / the DB itself), not on this host.
# Per the contract: "ABSENCE IS AN ANSWER" — discovery returns an empty list and
# check mode returns UNKNOWN when the product/data source is not on the host.

def main(ctx, params):
    if params.get("_discover"):
        # The data source (sys.database_mirroring) is not present on this host —
        # it is queried on a remote SQL Server instance. Without Checkmk's MSSQL
        # special agent running against that DB, there is nothing to discover here.
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    # No on-host source available; report UNKNOWN rather than inventing values.
    return {
        "changed": False,
        "msg": "no MSSQL mirroring data source on this host (queried via remote SQL Server)",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "sys.database_mirroring is not available on this host",
        },
    }