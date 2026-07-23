# ===== Starlark check module for mcafee_webgateway_time_to_resolve_dns =====
# Translated from Checkmk plugin: cmk/plugins/mcafee/agent_based/mcafee_webgateway_time_to_resolve_dns.py
# Note: The McAfee Web Gateway has been rebranded to Skyhigh Secure Web Gateway v12.2.2+

def main(ctx, params):
    # Discovery mode: report a single service if DNS resolution data is available
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/mcafee-webgateway/misc.json"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # Use json.decode only if output exists and is non-empty
        if res.stdout.strip():
            data = json.decode(res.stdout)
            if data.get("time_to_resolve_dns") != None:
                return {"changed": False, "msg": "discovered 1 item",
                        "data": {"discovery": [{"item": "", "params": {}, "metrics": ["time_to_resolve_dns"]}]}}

        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    # Check mode: extract DNS resolution time and apply thresholds
    res = ctx.run(["cat", "/var/lib/mcafee-webgateway/misc.json"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse JSON only if output exists and is non-empty
    data = json.decode(res.stdout)

    dns_time = data.get("time_to_resolve_dns")
    if dns_time == None:
        return {"changed": False, "msg": "data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get thresholds from params with defaults: warn=2.0s, crit=5.0s
    warn = 2.0
    crit = 5.0
    if params.get("time_to_resolve_dns") != None:
        if type(params.get("time_to_resolve_dns")) == "dict":
            warn = params.get("time_to_resolve_dns").get("upper", 2.0)
            crit = params.get("time_to_resolve_dns").get("upper_crit", 5.0)
        else:
            warn = params.get("warn", 2.0)
            crit = params.get("crit", 5.0)

    # Convert to numeric values safely
    dns_time_sec = float(dns_time)
    warn_sec = float(warn)
    crit_sec = float(crit)

    # Determine state: upper levels -> WARN if >= warn, CRIT if >= crit
    state = "OK"
    if dns_time_sec >= crit_sec:
        state = "CRIT"
    elif dns_time_sec >= warn_sec:
        state = "WARN"

    # Build human-readable message (Checkmk-style)
    ts_str = ""
    if dns_time_sec < 60:
        ts_str = "%f s" % dns_time_sec
    elif dns_time_sec < 3600:
        ts_str = "%f min" % (dns_time_sec / 60.0)
    else:
        ts_str = "%f h" % (dns_time_sec / 3600.0)

    return {"changed": False, "msg": "Time to resolve DNS: %s" % ts_str,
            "data": {"state": state, "metrics": {"time_to_resolve_dns": dns_time_sec}, "details": ""}}