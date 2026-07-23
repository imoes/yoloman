# Mapping from SNMP operability string to (state_code, status_text)
# Based on MAP_OPERABILITY in cmk.plugins.cisco.lib_ucs
OPERABILITY_MAP = {
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

def main(ctx, params):
    # Discovery mode: only one service always exists
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: get RAID controller info via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Query the RAID controller section:
    # .1.3.6.1.4.1.9.9.719.1.45.1.1.5 = cucsRaidControllerModel
    # .1.3.6.1.4.1.9.9.719.1.45.1.1.7 = cucsRaidControllerOperability
    # .1.3.6.1.4.1.9.9.719.1.45.1.1.14 = cucsRaidControllerSerial
    # .1.3.6.1.4.1.9.9.719.1.45.1.1.17 = cucsRaidControllerVendor
    base_oid = ".1.3.6.1.4.1.9.9.719.1.45.1.1"
    
    oids = ["5", "7", "14", "17"]
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse SNMP output to find our OIDs
    model = ""
    operability_str = ""
    serial = ""
    vendor = ""
    
    for line in res.stdout.splitlines():
        if not line:
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract value type and content (e.g., "STRING: value" or "STRING: "value"")
        if value_part.startswith("STRING: "):
            value = value_part[8:].strip().strip('"')
        else:
            value = value_part
        
        # Match specific OID suffixes
        if oid_part.endswith(".5"):
            model = value
        elif oid_part.endswith(".7"):
            operability_str = value.strip()
        elif oid_part.endswith(".14"):
            serial = value
        elif oid_part.endswith(".17"):
            vendor = value

    # Ensure we have data
    if not model:
        return {
            "changed": False,
            "msg": "no RAID controller data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Map operability to state code and status text
    state_code = 2  # default to CRIT
    status_text = "unknown"
    if operability_str in OPERABILITY_MAP:
        state_code, status_text = OPERABILITY_MAP[operability_str]
    
    # Determine Checkmk state
    state_str = "OK" if state_code == 0 else ("WARN" if state_code == 1 else "CRIT")

    # Build summary message
    msg_parts = []
    msg_parts.append("Status: %s" % status_text)
    msg_parts.append("Model: %s" % model)
    msg_parts.append("Vendor: %s" % vendor)
    msg_parts.append("Serial number: %s" % serial)
    summary = ", ".join(msg_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": "",
        },
    }
