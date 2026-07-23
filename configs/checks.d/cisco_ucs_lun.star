def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Discovery is single-service (item == ""), run SNMP probe
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.9.9.719.1.45.8.1.14",
        ".1.3.6.1.4.1.9.9.719.1.45.8.1.13",
        ".1.3.6.1.4.1.9.9.719.1.45.8.1.9"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output: extract the three OIDs
    lines = res.stdout.splitlines()
    luntype = None
    lunsize = None
    lunoperability = None
    
    for line in lines:
        line = line.strip()
        if line.startswith(".1.3.6.1.4.1.9.9.719.1.45.8.1.14"):
            parts = line.split()
            if len(parts) >= 2:
                luntype = parts[1].strip()
        elif line.startswith(".1.3.6.1.4.1.9.9.719.1.45.8.1.13"):
            parts = line.split()
            if len(parts) >= 2:
                lunsize = parts[1].strip()
        elif line.startswith(".1.3.6.1.4.1.9.9.719.1.45.8.1.9"):
            parts = line.split()
            if len(parts) >= 2:
                lunoperability = parts[1].strip()

    if luntype == None or lunsize == None or lunoperability == None:
        return {
            "changed": False,
            "msg": "missing LUN data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map operability
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
        "84": (2, "chassisLimitExceeded"),
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
    
    # Map LUN type
    map_luntype = {
        "0": (2, "unspecified"),
        "1": (1, "simple"),
        "2": (0, "mirror"),
        "3": (1, "stripe"),
        "4": (0, "lun"),
        "5": (0, "stripeParity"),
        "6": (0, "stripeDualParity"),
        "7": (0, "mirrorStripe"),
        "8": (0, "stripeParityStripe"),
        "9": (0, "stripeDualParityStripe"),
    }

    # Determine state
    state_info = MAP_OPERABILITY.get(lunoperability, (3, "Unknown, status code %s" % lunoperability))
    state = state_info[0]
    state_readable = state_info[1]
    
    mode_info = map_luntype.get(luntype, (3, "Unknown, status code %s" % luntype))
    mode_state = mode_info[0]
    mode_state_readable = mode_info[1]

    # Size: convert MB to bytes (render.bytes expects bytes)
    size_mb = 0
    if lunsize.isdigit():
        size_mb = int(lunsize)
    size_readable = "%d MB" % size_mb

    # Checkmk uses State.OK=0, WARN=1, CRIT=2, UNKNOWN=3
    # Return appropriate states
    state_final = "CRIT" if state == 2 else ("WARN" if state == 1 else ("UNKNOWN" if state == 3 else "OK"))
    mode_state_final = "CRIT" if mode_state == 2 else ("WARN" if mode_state == 1 else ("UNKNOWN" if mode_state == 3 else "OK"))

    msg_parts = []
    msg_parts.append("Status: %s" % state_readable)
    msg_parts.append("Size: %s" % size_readable)
    msg_parts.append("Mode: %s" % mode_state_readable)
    
    return {
        "changed": False,
        "msg": "; ".join(msg_parts),
        "data": {
            "state": state_final,
            "metrics": {},
            "details": ""
        },
    }
