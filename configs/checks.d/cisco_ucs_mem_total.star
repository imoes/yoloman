# ===== checkmk.cisco_ucs_mem_total =====
# Translated to a read-only Starlark check module.
# Source: cmk/plugins/cisco/agent_based/cisco_ucs_mem_total.py
# SNMP check: reads cucsComputeRackUnitAvailableMemory
#   OID base = .1.3.6.1.4.1.9.9.719.1.9.35.1
#   column  .9 = available memory (scalar-ish single value)
# Detection: sysObjectID contains one of the Cisco UCS enterprise OIDs.

def _detect_ucs(ctx, community):
    # Probe the real thing: read sysObjectID (.1.3.6.1.2.1.1.2.0) and check
    # it contains a known Cisco UCS enterprise number.
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", ctx.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    oid = res.stdout
    if not oid:
        return False
    for needle in _UCS_SYSOID_NEEDLES:
        if needle in oid:
            return True
    return False

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = "1.3.6.1.4.1.9.9.719.1.9.35.1"
    col_oid = "1.3.6.1.4.1.9.9.719.1.9.35.1.9"

    if params.get("_discover"):
        # Discovery: a single-service check (item ""). Only yield the service
        # when the monitored device is genuinely a Cisco UCS.
        if not _detect_ucs(ctx, community):
            return {"changed": False, "msg": "not a Cisco UCS device",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {},
                     "metrics": ["memory_total"]},
                ]}}

    # Check mode: read the scalar value with -Oqv (bare value only).
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, col_oid],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False,
                "msg": "unable to query memory total via SNMP: " + res.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val = res.stdout.strip()
    if not val:
        return {"changed": False,
                "msg": "no memory total value returned via SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # snmpget -Oqv yields the bare value (e.g. "4096").
    digits = val
    if not digits.isdigit():
        return {"changed": False,
                "msg": "unexpected memory total value: " + val,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_memory = int(digits)
    return {"changed": False,
            "msg": "Total Memory: %d MB" % total_memory,
            "data": {"state": "OK",
                     "metrics": {"memory_total": total_memory},
                     "details": ""}}

_UCS_SYSOID_NEEDLES = [
    "1.3.6.1.4.1.9.1.1682",
    "1.3.6.1.4.1.9.1.1683",
    "1.3.6.1.4.1.9.1.1684",
    "1.3.6.1.4.1.9.1.1685",
    "1.3.6.1.4.1.9.1.2178",
    "1.3.6.1.4.1.9.1.2179",
    "1.3.6.1.4.1.9.1.2424",
    "1.3.6.1.4.1.9.1.2492",
    "1.3.6.1.4.1.9.1.2493",
    "1.3.6.1.4.1.9.1.3100",
]