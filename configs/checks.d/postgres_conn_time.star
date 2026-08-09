# ===== check plugin: cmk check postgres_conn_time =====
# A read-only Starlark check module. Reproduces the Checkmk check
# "postgres_conn_time" using the on-host PostgreSQL server as the data
# source. The connection time is measured by timing the connection
# handshake via psql with \timing enabled.

HOST_LABEL_OS_FAMILY_DEFAULT = "linux"

def _probe_pg(ctx, host, port, timeout):
    # Returns (reachable, conn_time, err).
    # reachable: bool — whether a PostgreSQL server answered.
    # conn_time: float — measured connection time in seconds (0.0 if not).
    # err: str — empty on success, a diagnostic otherwise.
    ready = ctx.run(
        ["pg_isready", "-h", host, "-p", str(port), "-t", str(timeout)],
        mutates=False,
    )
    if ready.rc == 127:
        return (False, 0.0, "pg_isready not found")
    if ready.rc != 0:
        return (False, 0.0, "PostgreSQL not reachable on %s:%s" % (host, port))

    timed = ctx.run(
        ["psql", "-h", host, "-p", str(port), "-t", "-A", "-w",
         "-c", "\\timing on\nSELECT 1"],
        mutates=False,
    )
    if timed.rc == 127:
        return (False, 0.0, "psql not found")
    if timed.rc != 0:
        return (False, 0.0, "Login into database failed")

    conn_time = 0.0
    parsed = False
    for line in timed.stdout.splitlines():
        low = line.lower()
        if ("time" in low or "ms" in low) and not parsed:
            parts = line.replace(":", " ").replace("=", " ").split()
            for p in parts:
                p2 = p.replace(".", "", 1).replace("-", "", 1)
                if p2.isdigit():
                    conn_time = float(p) / 1000.0
                    parsed = True
                    break
        if parsed:
            break
    if not parsed:
        return (False, 0.0, "could not parse connection time")
    return (True, conn_time, "")


def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 5432)
    timeout = params.get("timeout", 5)
    item = params.get("item", "")

    if params.get("_discover"):
        reachable, conn_time, err = _probe_pg(ctx, host, port, timeout)
        if not reachable:
            return {
                "changed": False,
                "msg": "no PostgreSQL instance found",
                "data": {"discovery": []},
            }
        instance_name = (host + ":" + str(port)).upper()
        facts = ctx.facts()
        os_family = facts.get("os_family", HOST_LABEL_OS_FAMILY_DEFAULT)
        return {
            "changed": False,
            "msg": "discovered 1 PostgreSQL instance",
            "data": {
                "discovery": [
                    {
                        "item": instance_name,
                        "params": {},
                        "metrics": ["connection_time"],
                    },
                ],
                "host_labels": {
                    "cmk/os_family": os_family,
                },
            },
        }

    reachable, conn_time, err = _probe_pg(ctx, host, port, timeout)
    if not reachable:
        return {
            "changed": False,
            "msg": err,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "PostgreSQL not reachable on %s:%s" % (host, port),
            },
        }

    summary = "%s seconds" % conn_time
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {"connection_time": conn_time},
            "details": "",
        },
    }