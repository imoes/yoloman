# ===== Checkmk check: bvip_util → read-only Starlark check module =====
# Monitors Bosch AUTODOME / VIP-X camera CPU utilization via SNMP.
# The BVIP SNMP table lives at .1.3.6.1.4.1.3967.1.1.9.1 with columns:
#   1 = Total CPU idle  2 = Coder CPU idle  3 = VCA CPU idle
# Utilization = 100 - idle.

def _detect_bvip(ctx, community, host):
    """Return True if the host is a Bosch BVIP device (per DETECT_BVIP)."""
    sys_desc_oid = ".1.3.6.1.2.1.1.1.0"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, sys_desc_oid],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0 or not res.stdout.strip():
        return False
    desc = res.stdout.strip()
    markers = ["flexidome", "vip-x", "dinion", "autodome"]
    for m in markers:
        if desc.find(m) != -1:
            return True
    return False


def _fetch_util(ctx, community, host):
    """Fetch the BVIP CPU idle counters. Returns dict item->idle or None."""
    base = ".1.3.6.1.4.1.3967.1.1.9.1"
    cols = ["1", "2", "3"]
    vals = {}
    for i in range(len(cols)):
        oid = base + "." + cols[i]
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                       host, oid], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return None
        raw = res.stdout.strip()
        if not raw.isdigit():
            return None
        vals[i] = int(raw)
    return vals


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    levels = params.get("levels", (90.0, 95.0))
    warn = levels[0]
    crit = levels[1]

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        if not _detect_bvip(ctx, community, host):
            return {"changed": False, "msg": "host is not a BVIP device",
                    "data": {"discovery": []}}
        if _fetch_util(ctx, community, host) == None:
            return {"changed": False, "msg": "BVIP device not responding for cpu util",
                    "data": {"discovery": []}}
        out = []
        for name in ["Total", "Coder", "VCA"]:
            out.append({"item": name,
                        "params": {"levels": (warn, crit)},
                        "metrics": ["utilization"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    # --- CHECK MODE ---
    if not _detect_bvip(ctx, community, host):
        return {"changed": False, "msg": "host is not a BVIP device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vals = _fetch_util(ctx, community, host)
    if vals == None:
        return {"changed": False, "msg": "no BVIP cpu utilization data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")
    items = {"Total": 0, "Coder": 1, "VCA": 2}
    idx = items.get(item)
    if idx == None:
        return {"changed": False, "msg": "unknown item: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    idle = vals[idx]
    usage = 100 - idle if item == "Total" else idle
    state = "CRIT" if usage >= crit else ("WARN" if usage >= warn else "OK")
    msg = "CPU utilization %s: %f%%" % (item, usage)
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"utilization": usage},
                     "details": ""}}