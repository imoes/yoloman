# ===== translated from cmk/plugins/eltek/agent_based/eltek_systemstatus.py =====
# System Status — a single-service, read-only SNMP check.
#
# Detects the Eltek device via its enterprise OID prefix and reads the
# scalar systemOperationalStatus (0 = sysDescr OID .1.3.6.1.2.1.1.2.0,
# value must start with .1.3.6.1.4.1.12148.9). Fetches the operational
# status scalar at .1.3.6.1.4.1.12148.9.2.2.0 and maps it to a verdict.

# Operational-status raw-value -> (state, human readable)
_STATUS_MAP = {
    "0": ("CRIT", "float, voltage regulated"),
    "1": ("OK",   "float, temperature comp. regulated"),
    "2": ("CRIT", "battery boost"),
    "3": ("CRIT", "battery test"),
}
# Anything else is treated as UNKNOWN (no explicit mapping in the source).


def main(ctx, params):
    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        version = params.get("snmp_version", "2c")

        # Probe for the real thing first: the Eltek enterprise OID.
        sys_oid = "1.3.6.1.2.1.1.2.0"
        res = ctx.run(
            ["snmpget", "-" + version, "-c", community, "-Oqv", host, sys_oid],
            mutates=False,
        )
        # rc 127 -> snmp tools not installed; rc != 0 or empty -> not an Eltek device.
        if res.rc == 127:
            return {"changed": False, "msg": "snmpget not installed",
                    "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout.strip():
            # Not an Eltek device (DETECT_ELTEK check).
            return {"changed": False, "msg": "not an Eltek device",
                    "data": {"discovery": []}}

        sys_descr = res.stdout.strip()
        if not sys_descr.startswith(".1.3.6.1.4.1.12148.9"):
            return {"changed": False, "msg": "not an Eltek device",
                    "data": {"discovery": []}}

        # This is a single-service check: one item, no per-item breakdown.
        return {"changed": False,
                "msg": "discovered System Status",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}

    # ---- CHECK MODE (single-service, item is "") ----
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("snmp_version", "2c")

    # First confirm the device is an Eltek device.
    sys_oid = "1.3.6.1.2.1.1.2.0"
    res = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host, sys_oid],
        mutates=False,
    )
    if res.rc == 127:
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no SNMP response from host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_descr = res.stdout.strip()
    if not sys_descr.startswith(".1.3.6.1.4.1.12148.9"):
        return {"changed": False,
                "msg": "host is not an Eltek device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read the operational status scalar (.1.3.6.1.4.1.12148.9.2.2.0).
    status_oid = "1.3.6.1.4.1.12148.9.2.2.0"
    sres = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host, status_oid],
        mutates=False,
    )
    if sres.rc == 127:
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sres.rc != 0 or not sres.stdout.strip():
        return {"changed": False, "msg": "could not read operational status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = sres.stdout.strip()
    # -Oqv on an INTEGER scalar yields the bare integer value.
    if raw not in _STATUS_MAP:
        return {"changed": False,
                "msg": "unknown operational status: %s" % raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state, readable = _STATUS_MAP[raw]
    return {"changed": False,
            "msg": "Operational status: %s" % readable,
            "data": {"state": state, "metrics": {}, "details": ""}}