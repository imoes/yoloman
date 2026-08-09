# Map from Cisco UCS operability code to (State index, label).
# State index: 0 = OK, 1 = WARN, 2 = CRIT.
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

# SysOID base for Cisco UCS platforms the check detects.
CISCO_UCS_SYOID = ".1.3.6.1.4.1.9."

# SNMP base OID for the RAID controller table.
RAID_BASE = ".1.3.6.1.4.1.9.9.719.1.45.1.1"

# OID suffixes within the RAID table (relative to RAID_BASE).
OID_MODEL = "5"
OID_OPERABILITY = "7"
OID_SERIAL = "14"
OID_VENDOR = "17"

# String-to-state mapping.
STATE_OK = "OK"
STATE_WARN = "WARN"
STATE_CRIT = "CRIT"
STATE_UNKNOWN = "UNKNOWN"

STATE_BY_INDEX = {0: STATE_OK, 1: STATE_WARN, 2: STATE_CRIT}


def _state_name(idx):
    return STATE_BY_INDEX.get(idx, STATE_UNKNOWN)


def _probe_snmpget(ctx, community, host, oid):
    return ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )


def _probe_sysdesc(ctx, community, host):
    # sysDescr (.1.3.6.1.2.1.1.1.0) lets us confirm this is a Cisco UCS device.
    return ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )


def _probe_sysoid(ctx, community, host):
    # sysObjectID (.1.3.6.1.2.1.1.2.0) is what Checkmk's DETECT matches on.
    return ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )


def _sysoid_matches(sysoid):
    # Checkmk DETECT matches sysObjectID against a set of Cisco UCS prefixes.
    if sysoid == None or sysoid == "":
        return False
    for prefix in [
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
    ]:
        if sysoid == prefix:
            return True
    return False


def _snmp_available(ctx, community, host):
    # Probe for the real thing: snmpget must exist (rc != 127) and respond.
    res = _probe_sysoid(ctx, community, host)
    if res.rc == 127:
        return False
    if res.rc != 0:
        return False
    return True


def _fetch_raid(ctx, community, host):
    model = ""
    operability_code = ""
    serial = ""
    vendor = ""
    ok = True

    res = _probe_snmpget(ctx, community, host, RAID_BASE + "." + OID_MODEL)
    if res.rc == 127 or res.rc != 0:
        ok = False
        model = ""
    else:
        model = res.stdout.strip()

    res = _probe_snmpget(ctx, community, host, RAID_BASE + "." + OID_OPERABILITY)
    if res.rc == 127 or res.rc != 0:
        ok = False
        operability_code = ""
    else:
        operability_code = res.stdout.strip()

    res = _probe_snmpget(ctx, community, host, RAID_BASE + "." + OID_SERIAL)
    if res.rc == 127 or res.rc != 0:
        ok = False
        serial = ""
    else:
        serial = res.stdout.strip()

    res = _probe_snmpget(ctx, community, host, RAID_BASE + "." + OID_VENDOR)
    if res.rc == 127 or res.rc != 0:
        ok = False
        vendor = ""
    else:
        vendor = res.stdout.strip()

    if not ok:
        return {"ok": False, "model": "", "operability_code": "", "serial": "", "vendor": ""}

    return {
        "ok": True,
        "model": model,
        "operability_code": operability_code,
        "serial": serial,
        "vendor": vendor,
    }


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")

        # Probe for the real thing: is snmp available and is this a Cisco UCS device?
        if not _snmp_available(ctx, community, host):
            return {"changed": False, "msg": "no snmp agent reachable",
                    "data": {"discovery": []}}

        sysoid_res = _probe_sysoid(ctx, community, host)
        sysoid = sysoid_res.stdout.strip() if sysoid_res.rc == 0 else ""
        if not _sysoid_matches(sysoid):
            return {"changed": False, "msg": "not a cisco ucs device",
                    "data": {"discovery": []}}

        raid = _fetch_raid(ctx, community, host)
        if not raid.get("ok", False):
            return {"changed": False, "msg": "cisco ucs raid data unavailable",
                    "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "RAID Controller",
                        "params": {},
                        "metrics": [],
                    }
                ],
            },
        }

    # Check mode: evaluate the single RAID Controller service (item ""]).
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if not _snmp_available(ctx, community, host):
        return {"changed": False, "msg": "no snmp agent reachable",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    sysoid_res = _probe_sysoid(ctx, community, host)
    sysoid = sysoid_res.stdout.strip() if sysoid_res.rc == 0 else ""
    if not _sysoid_matches(sysoid):
        return {"changed": False, "msg": "not a cisco ucs device",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    raid = _fetch_raid(ctx, community, host)
    if not raid.get("ok", False):
        return {"changed": False, "msg": "cisco ucs raid data unavailable",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    operability_code = raid.get("operability_code", "")

    if operability_code not in MAP_OPERABILITY:
        return {"changed": False,
                "msg": "unknown operability code: %s" % operability_code,
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    state_idx, operability_label = MAP_OPERABILITY[operability_code]
    state = _state_name(state_idx)

    model = raid.get("model", "")
    vendor = raid.get("vendor", "")
    serial = raid.get("serial", "")

    summary = "Status: %s" % operability_label
    details = "Model: %s\nVendor: %s\nSerial number: %s" % (model, vendor, serial)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }