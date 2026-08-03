# Arbor Peakflow (SP/TMS) / Pravail disk usage percentage check.
# Translated from Checkmk agent-based plugin to a read-only Starlark check
# that polls the underlying SNMP OIDs directly.

# OID bases per product family (matching the Checkmk SNMPTree definitions).
_OID_SP = ".1.3.6.1.4.1.9694.1.4.2.1"
_OID_TMS = ".1.3.6.1.4.1.9694.1.5.2"
_OID_PRAVAIL = ".1.3.6.1.4.1.9694.1.6.2"

# Leaf OID carrying the disk usage percentage (last subidentifier of the
# SNMPTree fetch, e.g. base + ".4.0" for SP, ".6.0" for TMS/Pravail).
_USAGE_LEAF = {
    "peakflow_sp": "4.0",
    "peakflow_tms": "6.0",
    "pravail": "6.0",
}

# FILESYSTEM_DEFAULT_PARAMS equivalent (warn, crit) used by the Checkmk source.
_DEFAULT_LEVELS = (80.0, 90.0)


def _get_usage(ctx, host, community, base, leaf):
    """Walk one scalar disk-usage OID; return int percent or None."""
    oid = base + "." + leaf
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    out = res.stdout.strip()
    if not out:
        return None
    return int(out)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    product = params.get("product", "peakflow_tms")

    if product not in _OID_BASES():
        fail("unsupported product: " + str(product))

    base = _OID_BASES()[product]
    leaf = _USAGE_LEAF[product]

    # ---- Discovery mode ----
    if params.get("_discover"):
        # The Checkmk check always discovers a single "/" item. Here we
        # gate discovery on whether the product's SNMP scalar actually
        # responds — absence means the product is not present.
        usage = _get_usage(ctx, host, community, base, leaf)
        if usage == None:
            return {"changed": False, "msg": "no arbor " + product + " found",
                    "data": {"discovery": []}}
        levels = params.get("levels", _DEFAULT_LEVELS)
        warn = levels[0] if type(levels) == "list" else levels[0]
        crit = levels[1] if type(levels) == "list" else levels[1]
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "/",
                     "params": {"levels_upper": (warn, crit)},
                     "metrics": ["disk_utilization"]},
                ]}}

    # ---- Check mode ----
    usage = _get_usage(ctx, host, community, base, leaf)
    if usage == None:
        return {"changed": False,
                "msg": "no arbor " + product + " disk usage data available",
                "data": {"state": "UNKNOWN",
                         "metrics": {},
                         "details": "SNMP query for " + base + "." + leaf + " failed"}}

    levels = params.get("levels", _DEFAULT_LEVELS)
    if type(levels) == "list":
        warn = levels[0]
        crit = levels[1]
    else:
        warn = levels
        crit = levels
    # Fallback if a single tuple default wasn't unpacked.
    if warn == crit:
        warn, crit = _DEFAULT_LEVELS

    state = "CRIT" if usage >= crit else ("WARN" if usage >= warn else "OK")
    pct = "%f%%" % usage

    return {"changed": False,
            "msg": "Disk usage " + pct,
            "data": {"state": state,
                     "metrics": {"disk_utilization": float(usage) / 100.0,
                                 "used_percent": usage},
                     "details": "Disk usage " + pct}}


def _OID_BASES():
    return {"peakflow_sp": _OID_SP,
            "peakflow_tms": _OID_TMS,
            "pravail": _OID_PRAVAIL}