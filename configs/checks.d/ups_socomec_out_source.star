# ups_socomec_out_source starlark check module for yolo-man agent
# Translated from Checkmk check: ups_socomec_out_source
# Read-only: only probes via SNMP, never mutates.

SOURCE_OID = ".1.3.6.1.4.1.4555.1.1.1.1.4.1"
SYSOID_OID = ".1.3.6.1.2.1.1.2.0"
SYSOID_EXPECTED_PREFIX = ".1.3.6.1.4.1.4555.1.1.1"

SOURCE_STATES = {
    "1": ("UNKNOWN", "Unknown"),
    "2": ("CRIT", "On inverter"),
    "3": ("OK", "On mains"),
    "4": ("OK", "Eco mode"),
    "5": ("WARN", "On bypass"),
    "6": ("OK", "Standby"),
    "7": ("WARN", "On maintenance bypass"),
    "8": ("CRIT", "UPS off"),
    "9": ("OK", "Normal mode"),
}


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    item = params.get("item", "")

    if params.get("_discover"):
        sys_res = ctx.run(
            ["snmpget", "-v" + version, "-c", community, "-Oqv", host, SYSOID_OID],
            mutates=False,
        )
        if sys_res.skipped or sys_res.rc != 0:
            return {
                "changed": False,
                "msg": "socomec device not detected (sysOID query failed)",
                "data": {"discovery": []},
            }
        sys_oid = sys_res.stdout.strip()
        if not sys_oid.startswith(SYSOID_EXPECTED_PREFIX):
            return {
                "changed": False,
                "msg": "socomec device not detected (sysOID mismatch)",
                "data": {"discovery": []},
            }
        res = ctx.run(
            ["snmpget", "-v" + version, "-c", community, "-Oqv", host, SOURCE_OID],
            mutates=False,
        )
        if res.skipped or res.rc != 0:
            return {
                "changed": False,
                "msg": "no output source data (OID query failed)",
                "data": {"discovery": []},
            }
        raw = res.stdout.strip()
        if raw == "" or not raw.isdigit():
            return {
                "changed": False,
                "msg": "no output source data (empty/non-numeric value)",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 output source item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["out_source_state"],
                    }
                ]
            },
        }

    # CHECK MODE
    sys_res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, SYSOID_OID],
        mutates=False,
    )
    if sys_res.skipped or sys_res.rc != 0:
        return {
            "changed": False,
            "msg": "socomec device not reachable (sysOID query failed)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sys_oid = sys_res.stdout.strip()
    if not sys_oid.startswith(SYSOID_EXPECTED_PREFIX):
        return {
            "changed": False,
            "msg": "socomec device not detected (sysOID mismatch)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, SOURCE_OID],
        mutates=False,
    )
    if res.skipped or res.rc != 0:
        return {
            "changed": False,
            "msg": "no output source data (OID query failed)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = res.stdout.strip()
    if raw == "" or not raw.isdigit():
        return {
            "changed": False,
            "msg": "no output source data (empty/non-numeric value: %s)" % raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state, text = SOURCE_STATES.get(raw, ("UNKNOWN", "Unknown"))
    return {
        "changed": False,
        "msg": text,
        "data": {
            "state": state,
            "metrics": {"out_source_state": int(raw)},
            "details": text,
        },
    }