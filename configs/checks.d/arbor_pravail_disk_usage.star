# Arbor Pravail / Peakflow disk usage — SNMP check (single-service, item "/")
# Translates Checkmk's arbor_pravail_disk_usage, arbor_peakflow_sp_disk_usage,
# and arbor_peakflow_tms_disk_usage checks.

def main(ctx, params):
    # SNMP params
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    # Thresholds (filesystem default: warn 80, crit 90 — upper levels)
    levels = params.get("levels", (80, 90))
    warn = levels[0] if len(levels) >= 1 else 80
    crit = levels[1] if len(levels) >= 2 else 90
    # Which Arbor product to query — the Checkmk checks are separate plugins,
    # distinguished only by their SNMP base OID. We expose the base as a param.
    base_oid = params.get("base_oid", ".1.3.6.1.4.1.9694.1.6.2")
    col_oid = params.get("col_oid", "6.0")

    if params.get("_discover"):
        # Discovery: verify this is a real Arbor SNMP agent by probing the OID.
        # If the agent is unreachable or the OID returns nothing, no service.
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + "." + col_oid],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "not an Arbor disk-usage SNMP agent",
                    "data": {"discovery": []}}
        out = [{"item": "/", "params": {"levels": levels}, "metrics": ["disk_utilization"]}]
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": out}}

    item = params.get("item", "")

    # Grab the disk-usage percentage from the SNMP agent.
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + "." + col_oid],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Arbor disk usage not available: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    if not raw or not raw.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid disk usage value: " + raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = int(raw)

    state = "CRIT" if value >= crit else ("WARN" if value >= warn else "OK")
    pct = "%d%%" % value
    return {"changed": False, "msg": "Disk usage %s" % pct,
            "data": {"state": state,
                     "metrics": {"disk_utilization": float(value) / 100.0},
                     "details": "Disk usage: %s (WARN: %s, CRIT: %s)" % (pct, warn, crit)}}