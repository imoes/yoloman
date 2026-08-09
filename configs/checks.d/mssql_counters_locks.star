# ===== Checkmk check: mssql_counters_locks -> read-only Starlark =====
#
# Discovery & check for MSSQL lock counters (lock_requests/sec,
# lock_timeouts/sec, number_of_deadlocks/sec, lock_waits/sec).
#
# Data source: the host's MSSQL instance. We probe for the `sqlcmd` utility
# (rc == 127 means not installed). When present we query the standard perfmon
# DMV sys.dm_os_performance_counters for the lock counters and compute rates
# across consecutive reads using a value store persisted by the runtime.
#
# The Checkmk check computes rates between samples, so a single invocation
# cannot yield a meaningful rate. The agent persists a value store keyed by
# metric path; the first sample stores the raw counter and returns UNKNOWN
# "Cannot calculate rates yet"; subsequent samples compute
# (cur-prev)/(tcur-tprev) and grade against the per-counter levels supplied
# in params (default: no levels -> always OK).

# Counter display name -> perfmon counter name (as exposed by the DMV).
COUNTERS = [
    ("lock_requests/sec",        "Requests"),
    ("lock_timeouts/sec",        "Timeouts"),
    ("number_of_deadlocks/sec",  "Deadlocks"),
    ("lock_waits/sec",           "Waits"),
]

# SQL: select counter_name, cntr_value from the DMV. Match the "Locks"
# object (_Total instance) and the four lock counters. Single statement.
_SQL = "SELECT counter_name, cntr_value FROM sys.dm_os_performance_counters WHERE object_name LIKE '%:Locks' AND instance_name='_Total' AND counter_name IN ('lock_requests/sec','lock_timeouts/sec','number_of_deadlocks/sec','lock_waits/sec')"


# Module-level reference to the ctx object, set inside main().
_CTX = {"ctx": None}


def _c():
    return _CTX["ctx"]


def _sqlcmd_available():
    res = _c().run(["sqlcmd", "/?"], mutates=False)
    # rc 127 => binary missing; any other code means it exists.
    return res.rc != 127 and res.rc != 0


def _to_float(s):
    """Parse a numeric string without exceptions."""
    cleaned = s.strip()
    if cleaned == "":
        return None
    parts = cleaned.split(".", 1)
    if len(parts) == 1:
        if parts[0].lstrip("-").isdigit():
            return float(cleaned)
        return None
    intpart = parts[0].lstrip("-")
    fracpart = parts[1]
    if intpart.isdigit() and fracpart.isdigit():
        return float(cleaned)
    return None


def _query_mssql():
    """Run sqlcmd once, return dict counter_name -> float (or None)."""
    # sqlcmd: -S localhost, -E trusted conn, -b fail on error, -W trim,
    # -s "|" column separator, -h -1 suppress headers, -Q single query.
    res = _c().run(
        ["sqlcmd", "-S", "localhost", "-E", "-b", "-W", "-s", "|",
         "-h", "-1", "-Q", "SET NOCOUNT ON; " + _SQL],
        mutates=False,
    )
    if res.rc != 0:
        return None
    out = {}
    # Each row: counter_name|value
    for line in res.stdout.splitlines():
        if "|" not in line:
            continue
        name, val = line.split("|", 1)
        name = name.strip()
        val = val.strip()
        if not val:
            continue
        v = _to_float(val)
        if v != None:
            out[name] = v
    return out


def _rate_path(item, counter_key):
    return "mssql_counters.locks." + item + "." + counter_key


def _compute_rate(counter_key, item, cur, tcur):
    """Compute rate using the runtime value store.

    Returns (rate_or_None, detail_str). rate == None means
    "needs another sample" — mirrors Checkmk's get_rate_or_none.
    """
    ctx_obj = _c()
    path = _rate_path(item, counter_key)
    stored = ctx_obj.value_store_get(path)
    if stored == None:
        ctx_obj.value_store_set(path, {"t": tcur, "v": cur})
        return None, "Cannot calculate rates yet"
    prev = stored.get("v")
    tprev = stored.get("t")
    ctx_obj.value_store_set(path, {"t": tcur, "v": cur})
    dt = tcur - tprev
    if dt <= 0:
        return None, "Cannot calculate rates yet"
    rate = (cur - prev) / dt
    return rate, ""


def _grade(level_val, rate):
    """Grade an upper-level counter: WARN if >= warn, CRIT if >= crit."""
    if level_val == None:
        return "OK"
    # level_val may be a tuple/list (warn, crit) or a single threshold.
    warn = None
    crit = None
    t = type(level_val)
    if t == "list" or t == "tuple":
        vals = list(level_val)
        if len(vals) >= 1:
            warn = vals[0]
        if len(vals) >= 2:
            crit = vals[1]
    else:
        warn = level_val
    s = "OK"
    if crit != None and rate >= crit:
        s = "CRIT"
    elif warn != None and rate >= warn:
        s = "WARN"
    return s


def _worst(a, b):
    if a == "CRIT" or b == "CRIT":
        return "CRIT"
    if a == "WARN" or b == "WARN":
        return "WARN"
    return "OK"


def main(ctx, params):
    # Bind the runtime ctx for helpers.
    _CTX["ctx"] = ctx

    if params.get("_discover"):
        if not _sqlcmd_available():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        samples = _query_mssql()
        if samples == None or len(samples) == 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # One service per (object:instance) item. Canonical Checkmk item
        # for this host is "MSSQL:Locks _Total".
        item = "MSSQL:Locks _Total"
        metrics = [c[0].replace("/sec", "_per_second") for c in COUNTERS]
        items = [{"item": item, "params": {}, "metrics": metrics}]
        return {"changed": False,
                "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    # ---- Check mode (single item) ----
    item = params.get("item", "")
    time_point = params.get("_time", 0.0)
    if time_point == 0.0:
        time_point = ctx.now()

    samples = _query_mssql()
    if samples == None:
        return {"changed": False,
                "msg": "UNKNOWN: sqlcmd query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if len(samples) == 0:
        return {"changed": False,
                "msg": "no lock counters found for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details_lines = []
    worst = "OK"
    for counter_key, title in COUNTERS:
        if counter_key not in samples:
            continue
        cur = samples[counter_key]
        rate, detail = _compute_rate(counter_key, item, cur, time_point)
        if rate == None:
            # Mirror Checkmk's IgnoreResults — cannot grade yet.
            if detail:
                details_lines.append(detail)
            continue
        mk = counter_key.replace("/sec", "_per_second")
        metrics[mk] = rate
        state = _grade(params.get(counter_key), rate)
        worst = _worst(worst, state)
        details_lines.append(title + ": %f/s" % rate)

    # If we emitted NO metrics (all rates None / unknown), report UNKNOWN.
    if len(metrics) == 0:
        return {"changed": False,
                "msg": "Cannot calculate rates yet",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    summary = "; ".join(details_lines) if details_lines else ""
    return {"changed": False, "msg": summary,
            "data": {"state": worst, "metrics": metrics,
                     "details": "\n".join(details_lines)}}