# postgres_sessions.star — Checkmk check translation to read-only Starlark
# Monitors PostgreSQL session counts (idle/total, active/running) per instance.
# Read-only: never mutates system state, always changed=False.

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _title(s):
    if s == "":
        return s
    return s[0].upper() + s[1:]


def _get_instances(ctx):
    """Probe for the real PostgreSQL and return session counts per instance.

    Reproduces the Checkmk agent plugin output format:
        [[[instance]]]
        t <idle>
        f <active>

    Returns dict: { instance_name -> {"total": int, "running": int} }
    or None if PostgreSQL is not installed/usable.
    """
    ready = ctx.run(["pg_isready", "--version"], mutates=False)
    if ready.rc == 127:
        return None

    res = ctx.run(
        ["psql", "-At", "-d", "postgres", "-c",
         "SELECT count(*), count(*) FILTER (WHERE state = 'active') FROM pg_stat_activity"],
        mutates=False,
    )
    if res.rc != 0:
        return None

    parsed = {}
    for raw_line in res.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) != 2:
            continue
        total_str = parts[0]
        active_str = parts[1]
        if not total_str.isdigit() or not active_str.isdigit():
            continue
        parsed["postgres"] = {
            "total": int(total_str),
            "running": int(active_str),
        }

    return parsed


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def _discover(ctx, params):
    parsed = _get_instances(ctx)
    if parsed == None or len(parsed) == 0:
        return {
            "changed": False,
            "msg": "no postgres instances found",
            "data": {"discovery": []},
        }

    discovery = []
    for db, dbinfo in parsed.items():
        if dbinfo:
            discovery.append({
                "item": db,
                "params": {},
                "metrics": ["total", "running"],
            })

    return {
        "changed": False,
        "msg": "discovered %d instances" % len(discovery),
        "data": {"discovery": discovery},
    }


# ---------------------------------------------------------------------------
# Check
# ---------------------------------------------------------------------------

def _check(ctx, params):
    item = params.get("item", "")
    parsed = _get_instances(ctx)
    if parsed == None or item not in parsed:
        return {
            "changed": False,
            "msg": "login into database failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "no postgres instance found for item: " + item,
            },
        }

    data = parsed[item]
    idle = data["total"]
    running = data["running"]
    total = idle + running

    metrics = {}
    details_parts = []
    worst = "OK"

    for key, val in [("total", total), ("running", running)]:
        warn, crit = params.get(key, (None, None))
        state = "OK"
        if crit != None and val >= crit:
            state = "CRIT"
        elif warn != None and val >= warn:
            state = "WARN"

        metrics[key] = val

        txt = "%s: %d" % (_title(key), val)
        if state != "OK":
            txt += " (warn/crit at %s/%s)" % (warn, crit)
        details_parts.append(txt)

        if state == "CRIT":
            worst = "CRIT"
        elif state == "WARN" and worst != "CRIT":
            worst = "WARN"

    summary = "; ".join(details_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": worst,
            "metrics": metrics,
            "details": summary,
        },
    }