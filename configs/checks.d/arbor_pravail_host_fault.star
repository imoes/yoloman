def _detect_peakflow_tms(ctx, host, community):
    # Arbor Peakflow TMS: sysObjectID .1.3.6.1.4.1.9694.1.5 (enterprises.9694.1.5)
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return False
    oid = res.stdout.strip()
    return oid.startswith(".1.3.6.1.4.1.9694.1.5")

def _detect_pravail(ctx, host, community):
    # Arbor Pravail: sysObjectID .1.3.6.1.4.1.9694.1.6 (enterprises.9694.1.6)
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return False
    oid = res.stdout.strip()
    return oid.startswith(".1.3.6.1.4.1.9694.1.6")

def _is_device_present(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    return res.rc == 0 and bool(res.stdout and res.stdout.strip())

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_device_present(ctx, host, community):
            return {"changed": False, "msg": "no SNMP device reachable",
                    "data": {"discovery": []}}
        if not (_detect_peakflow_tms(ctx, host, community) or _detect_pravail(ctx, host, community)):
            return {"changed": False, "msg": "not an Arbor device",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered Host Fault",
                "data": {"discovery": [{"item": "", "params": {},
                                         "metrics": []}]}}

    item = params.get("item", "")
    # Base OID for arbor_pravail_host_fault
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.9694.1.6.2.1.0"], mutates=False)
    if res.rc != 0 or not res.stdout:
        # Try peakflow tms base as fallback
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.9694.1.5.2.1.0"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no host fault data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = res.stdout.strip()
    state = "OK" if value == "No Fault" else "CRIT"
    return {"changed": False, "msg": value,
            "data": {"state": state, "metrics": {}, "details": ""}}