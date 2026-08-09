# Translated Checkmk check: cisco_sma_resource_conservation
# Resource conservation — single-service SNMP check.

SNMP_BASE = ".1.3.6.1.4.1.15497.1.1.1"
SNMP_OID_VALUE = "6"  # leaf under the base

# Map raw integer value -> (state, summary)
_RC_STATES = {
    1: ("OK", "Resource conservation mode off"),
    2: ("WARN", "Resource conservation mode on (memory shortage)"),
    3: ("WARN", "Resource conservation mode on (queue space shortage)"),
    4: ("CRIT", "Resource conservation mode on (queue full)"),
}


def _probe_resource_conservation(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    oid = SNMP_BASE + "." + SNMP_OID_VALUE
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    # rc 0 -> success; rc 127 -> snmpget not installed; other -> not present
    if res.rc == 127:
        return {"present": False, "reason": "snmpget not installed"}
    if res.rc != 0:
        return {"present": False, "reason": "no response from host"}
    raw = res.stdout.strip()
    if raw == "":
        return {"present": True, "value": -999}
    # snmpget -Oqv prints only the bare value (no type tag, no = prefix)
    val = -999
    if raw.lstrip("-").isdigit():
        val = int(raw)
    return {"present": True, "value": val}


def main(ctx, params):
    if params.get("_discover"):
        probe = _probe_resource_conservation(ctx, params)
        if not probe.get("present", False):
            return {"changed": False, "msg": "device or snmpget not present",
                    "data": {"discovery": []}}
        # Single-service check: exactly one item with empty item name.
        entry = {"item": "", "params": {}, "metrics": []}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [entry]}}

    item = params.get("item", "")
    probe = _probe_resource_conservation(ctx, params)
    if not probe.get("present", False):
        reason = probe.get("reason", "unknown")
        return {"changed": False, "msg": reason,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = probe.get("value", -999)
    if value in _RC_STATES:
        state, summary = _RC_STATES[value]
    else:
        state = "UNKNOWN"
        summary = "Resource conservation status unknown"

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}