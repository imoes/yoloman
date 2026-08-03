# Checkmk check: mssql_connections
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# This check monitors Microsoft SQL Server database connection counts.
# The original Checkmk agent plugin emits parsed `<<<mssql_connections>>>` lines
# of the form:  <instance> <db_name> <connection_count>
# Here we must reproduce that data on-host by querying the running MSSQL Server
# directly (no Checkmk agent is present). We use the `sqlcmd` utility from the
# Microsoft ODBC / SQL Server tools package to query each SQL instance.

def main(ctx, params):
    # ---- shared helpers -------------------------------------------------
    def _probe_sqlcmd():
        # Presence probe for the real thing: the mssql-server tooling.
        # rc == 127 means not installed.
        return ctx.run(
            ["sqlcmd", "-?", "-b"],
            mutates=False,
        )

    def _list_instances():
        # Enumerate local SQL Server instances via the Windows/SqlLocalDb-style
        # lookup. On Linux, mssql-server typically runs a single default
        # instance named "MSSQLSERVER". We discover instances by checking the
        # mssql-server service list.
        res = ctx.run(
            ["systemctl", "list-units", "--type=service", "--no-legend"],
            mutates=False,
        )
        instances = []
        if res.rc == 0:
            for line in res.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 4 and "mssql-server.service" in parts[0]:
                    instances.append("MSSQLSERVER")
                    break
                if len(parts) >= 4 and parts[0].startswith("mssql-server-@"):
                    name = parts[0].rstrip(".service")
                    instances.append(name[15:])
        return instances

    def _query_connections(instance):
        # Query connection counts per database from a SQL instance.
        # Returns a list of (instance, db_name, connection_count) tuples.
        query = "SELECT DB_NAME(database_id) AS db_name, COUNT(*) AS connections FROM sys.dm_exec_connections GROUP BY DB_NAME(database_id)"
        res = ctx.run(
            [
                "sqlcmd",
                "-S", instance,
                "-Q", query,
                "-h", "-1",
                "-W",
                "-s", ",",
                "-b",
            ],
            mutates=False,
        )
        rows = []
        if res.rc == 0:
            for line in res.stdout.splitlines():
                fields = line.split(",")
                if len(fields) >= 2:
                    db_name = fields[0].strip()
                    conn_str = fields[1].strip()
                    if conn_str.isdigit():
                        rows.append((instance, db_name, int(conn_str)))
        return rows

    def _gather_all():
        # Gather all (instance, db_name, count) rows across instances.
        rows = []
        for inst in _list_instances():
            rows.extend(_query_connections(inst))
        return rows

    # ---- DISCOVERY MODE -------------------------------------------------
    if params.get("_discover"):
        probe = _probe_sqlcmd()
        if probe.rc == 127:
            return {
                "changed": False,
                "msg": "mssql_connections not applicable: sqlcmd not installed",
                "data": {"discovery": []},
            }

        all_rows = _gather_all()
        if len(all_rows) == 0:
            return {
                "changed": False,
                "msg": "mssql_connections: no SQL instances or databases found",
                "data": {"discovery": []},
            }

        # Build discovery entries keyed by "instance db_name" (matches Checkmk item format)
        seen = {}
        metrics_set = []
        for inst, db_name, count in all_rows:
            key = "%s %s" % (inst, db_name)
            if key not in seen:
                seen[key] = {"item": key, "params": {}, "metrics": ["connections"]}
                metrics_set.append(key)

        discovery = []
        for key in metrics_set:
            discovery.append(seen[key])

        return {
            "changed": False,
            "msg": "discovered %d mssql connection services" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- CHECK MODE -----------------------------------------------------
    item = params.get("item", "")

    probe = _probe_sqlcmd()
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "mssql_connections: sqlcmd not installed, cannot query SQL Server",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "sqlcmd utility is not available on this host",
            },
        }

    all_rows = _gather_all()
    if len(all_rows) == 0:
        return {
            "changed": False,
            "msg": "mssql_connections: no SQL instances found, item %s not present" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "no running SQL Server instances detected",
            },
        }

    # Find the requested item
    value = None
    for inst, db_name, count in all_rows:
        key = "%s %s" % (inst, db_name)
        if key == item:
            value = count
            break

    if value == None:
        return {
            "changed": False,
            "msg": "mssql_connections: item %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "the requested database connection item was not found on this host",
            },
        }

    # Apply threshold logic from params.
    # Checkmk default: levels=("no_levels", None) means no thresholds.
    # When levels are provided as a tuple (warn, crit), apply upper-level grading.
    levels = params.get("levels")
    state = "OK"
    if levels != None and type(levels) == "list" and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]
        # Guard: thresholds may be None (no_levels) or numeric
        if warn != None and crit != None:
            if value >= crit:
                state = "CRIT"
            elif value >= warn:
                state = "WARN"

    details = "%s: %d connections" % (item, value)

    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": {"connections": value},
            "details": details,
        },
    }