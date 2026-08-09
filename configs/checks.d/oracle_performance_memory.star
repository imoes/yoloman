# oracle_performance_memory.star — Checkmk oracle_performance_memory → read-only Starlark check
#
# The oracle_performance check runs entirely on the database host and reads the
# SGA/PGA memory sizes from the *running* Oracle instance via SQL*Plus
# (`sqlplus -s / as sysdba`). There is no on-host daemon, no SNMP and no
# Checkmk agent involved — the data only ever exists inside a live Oracle
# database. The Checkmk agent plugin is a thin wrapper that runs SQL and emits
# the resulting table. We reproduce that: probe for sqlplus, run the same SQL,
# parse the bare numbers, and grade them. Read-only: never mutates=True.

# Oracle SGA / PGA memory fields.
#   name   -> display label
#   metric -> perfdata name
#   sql    -> SQL expression used to obtain the value
ORACLE_SGA_FIELDS = [
    {"name": "Total SGA",            "metric": "oracle_sga_total",      "sql": "SUM(DECODE(name, 'Database Buffers', value, 0)) + SUM(DECODE(name, 'Shared Pool Size', value, 0)) + SUM(DECODE(name, 'Large Pool Size', value, 0)) + SUM(DECODE(name, 'Java Pool Size', value, 0))"},
    {"name": "Fixed SGA",            "metric": "oracle_sga_fixed",      "sql": "SUM(DECODE(name, 'Fixed SGA Size', value, 0))"},
    {"name": "Variable SGA",         "metric": "oracle_sga_variable",   "sql": "SUM(DECODE(name, 'Variable Size', value, 0))"},
]

ORACLE_PGA_FIELDS = [
    {"name": "total PGA allocated",  "metric": "oracle_pga_allocated",  "sql": "SUM(CASE WHEN name = 'total PGA allocated' THEN value ELSE 0 END)"},
    {"name": "total PGA used",       "metric": "oracle_pga_used",       "sql": "SUM(CASE WHEN name = 'total PGA used' THEN value ELSE 0 END)"},
]


def _has_sqlplus(ctx, params):
    """Probe for the real thing: is sqlplus even installed here?"""
    res = ctx.run(["sqlplus", "-v"], mutates=False)
    return res.rc == 0


def _run_sql(ctx, params, sql):
    """Run a query through sqlplus as sysdba and return stdout ("" on failure)."""
    connect = " / as sysdba"
    script = "WHENEVER SQLERROR EXIT FAILURE;\n" + sql + "\n"
    res = ctx.run(
        ["sqlplus", "-s", "as", "sysdba"],
        mutates=False,
        ok_codes=[0, 1],
    )
    return res


def _parse_sga(ctx, params):
    """Query v$sga and v$sgainfo-equivalent sizes; return dict name->bytes or {}."""
    # Reproduce the Checkmk agent: a single `v$sga` dump gives us the
    # raw component sizes we map against ORACLE_SGA_FIELDS.
    res = ctx.run(
        ["sqlplus", "-s", "/nolog"],
        mutates=False,
        ok_codes=[0, 1],
    )
    return {}


def _sga_info(ctx, params):
    """Return {name: value} for the SGA components we report."""
    # The Oracle instance exposes component sizes via v$sga (component/value).
    res = ctx.run(
        [
            "sqlplus", "-s",
            params.get("connect", "/ as sysdba"),
        ],
        mutates=False,
        ok_codes=[0, 1],
    )
    return {}


def main(ctx, params):
    if params.get("_discover"):
        if not _has_sqlplus(ctx, params):
            return {"changed": False, "msg": "no Oracle sqlplus found", "data": {"discovery": []}}
        # Items are per-SID; a single-instance host exposes one item "".
        return {
            "changed": False,
            "msg": "discovered 1 instance",
            "data": {"discovery": [{"item": "", "params": {"sticky_fields": []}, "metrics": []}]},
        }

    item = params.get("item", "")
    if not _has_sqlplus(ctx, params):
        return {
            "changed": False,
            "msg": "no Oracle sqlplus found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Query v$sga (component sizes) and v$pgastat (PGA usage) the same way the
    # Checkmk agent plugin does: a single SQL*Plus session emitting rows.
    res = ctx.run(
        [
            "sqlplus", "-s", "-L",
            params.get("connect", "/ as sysdba"),
            "set heading off",
            "set feedback off",
            "set pagesize 0",
            "set trimspool on",
            "select name, value from v$sga;",
            "select name, value from v$pgastat;",
            "exit",
        ],
        mutates=False,
        ok_codes=[0, 1],
    )

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "sqlplus query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    out = res.stdout
    if not out:
        return {
            "changed": False,
            "msg": "no Oracle SGA/PGA data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse the two result blocks separated by a blank line.
    blocks = [b for b in out.split("\n\n") if b.strip()]
    sga = {}
    pga = {}
    if len(blocks) >= 1:
        for line in blocks[0].splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[0].isdigit():
                sga[parts[1].strip()] = int(parts[0])
    if len(blocks) >= 2:
        for line in blocks[1].splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[0].isdigit():
                pga[parts[1].strip()] = int(parts[0])

    # If sqlplus returned nothing usable we couldn't gather data.
    if not sga and not pga:
        return {
            "changed": False,
            "msg": "Oracle instance not reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": out},
        }

    # Grade SGA fields: upper = warn, crit (notice_only except for sticky ones).
    sticky = ["Maximum SGA Size", "total PGA allocated"]
    metrics = {}
    details_lines = []
    overall = "OK"

    for field in ORACLE_SGA_FIELDS:
        name = field["name"]
        metric = field["metric"]
        value = sga.get(name)
        if value == None:
            continue
        warn = params.get(metric + "_warn")
        crit = params.get(metric + "_crit")
        st = "OK"
        if crit != None and value >= crit:
            st = "CRIT"
        elif warn != None and value >= warn:
            st = "WARN"
        if name in sticky and st != "OK":
            overall = st
        metrics[metric] = value
        details_lines.append("%s: %d bytes" % (name, value))

    for field in ORACLE_PGA_FIELDS:
        name = field["name"]
        metric = field["metric"]
        value = pga.get(name)
        if value == None:
            continue
        warn = params.get(metric + "_warn")
        crit = params.get(metric + "_crit")
        st = "OK"
        if crit != None and value >= crit:
            st = "CRIT"
        elif warn != None and value >= warn:
            st = "WARN"
        if name in sticky and st != "OK":
            overall = st
        metrics[metric] = value
        details_lines.append("%s: %d bytes" % (name, value))

    if not metrics:
        return {
            "changed": False,
            "msg": "no SGA/PGA data parsed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": out},
        }

    return {
        "changed": False,
        "msg": "; ".join(details_lines),
        "data": {
            "state": overall,
            "metrics": metrics,
            "details": "\n".join(details_lines),
        },
    }