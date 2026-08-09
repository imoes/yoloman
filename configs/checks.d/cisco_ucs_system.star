MAP_OPERABILITY = {
    "0": (2, "unknown"),
    "1": (0, "operable"),
    "2": (2, "inoperable"),
    "3": (2, "degraded"),
    "4": (1, "poweredOff"),
    "5": (2, "powerProblem"),
    "6": (0, "removed"),
    "7": (2, "voltageProblem"),
    "8": (2, "thermalProblem"),
    "9": (1, "performanceProblem"),
    "10": (1, "accessibilityProblem"),
    "11": (1, "identityUnestablishable"),
    "12": (2, "biosPostTimeout"),
    "13": (1, "disabled"),
    "14": (1, "malformedFru"),
    "51": (1, "fabricConnProblem"),
    "52": (1, "fabricUnsupportedConn"),
    "81": (1, "config"),
    "82": (2, "equipmentProblem"),
    "83": (2, "decomissioning"),
    "84": (1, "chassisLimitExceeded"),
    "100": (1, "notSupported"),
    "101": (1, "discovery"),
    "102": (2, "discoveryFailed"),
    "103": (1, "identify"),
    "104": (2, "postFailure"),
    "105": (1, "upgradeProblem"),
    "106": (1, "peerCommProblem"),
    "107": (0, "autoUpgrade"),
    "108": (1, "linkActivateBlocked"),
}

STATE_MAP = {0: "OK", 1: "WARN", 2: "CRIT"}

# Cisco UCS enterprise OIDs (from DETECT)
UCS_ENTERPRISE_OIDS = [
    ".1.3.6.1.4.1.9.1.1682",
    ".1.3.6.1.4.1.9.1.1683",
    ".1.3.6.1.4.1.9.1.1684",
    ".1.3.6.1.4.1.9.1.1685",
    ".1.3.6.1.4.1.9.1.2178",
    ".1.3.6.1.4.1.9.1.2179",
    ".1.3.6.1.4.1.9.1.2424",
    ".1.3.6.1.4.1.9.1.2492",
    ".1.3.6.1.4.1.9.1.2493",
    ".1.3.6.1.4.1.9.1.3100",
]

# sysObjectID OID
SYSOID_OID = ".1.3.6.1.2.1.1.2.0"

# SNMPTree base + OIDs for cisco_ucs_system
SYSTEM_BASE = ".1.3.6.1.4.1.9.9.719.1.9.35.1"
SYSTEM_OID_MODEL = "32"
SYSTEM_OID_SERIAL = "47"
SYSTEM_OID_STATUS = "43"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSOID_OID],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "not a Cisco UCS device", "data": {"discovery": []}}

        sysoid = res.stdout.strip()
        is_ucs = False
        for oid in UCS_ENTERPRISE_OIDS:
            if sysoid == oid:
                is_ucs = True
                break

        if not is_ucs:
            return {"changed": False, "msg": "not a Cisco UCS device", "data": {"discovery": []}}

        model_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSTEM_BASE + "." + SYSTEM_OID_MODEL],
            mutates=False,
        )
        serial_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSTEM_BASE + "." + SYSTEM_OID_SERIAL],
            mutates=False,
        )
        status_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSTEM_BASE + "." + SYSTEM_OID_STATUS],
            mutates=False,
        )

        if model_res.rc != 0 or serial_res.rc != 0 or status_res.rc != 0:
            return {"changed": False, "msg": "missing cisco_ucs_system SNMP data", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    },
                ],
            },
        }

    model_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSTEM_BASE + "." + SYSTEM_OID_MODEL],
        mutates=False,
    )
    serial_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSTEM_BASE + "." + SYSTEM_OID_SERIAL],
        mutates=False,
    )
    status_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSTEM_BASE + "." + SYSTEM_OID_STATUS],
        mutates=False,
    )

    if model_res.rc != 0 or serial_res.rc != 0 or status_res.rc != 0:
        return {
            "changed": False,
            "msg": "missing cisco_ucs_system SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    model = model_res.stdout.strip()
    serial = serial_res.stdout.strip()
    status = status_res.stdout.strip()

    entry = MAP_OPERABILITY.get(status)
    if entry:
        state_num = entry[0]
        state_readable = entry[1]
    else:
        state_num = 3
        state_readable = "Unknown, status code %s" % status

    state_name = STATE_MAP.get(state_num, "UNKNOWN")

    msg = "Status: %s, Model: %s, SN: %s" % (state_readable, model, serial)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_name,
            "metrics": {},
            "details": "",
        },
    }