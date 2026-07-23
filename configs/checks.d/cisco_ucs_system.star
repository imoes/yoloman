def main(ctx, params):
    # Discovery mode: yield one service for the system health check
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode: fetch system info via SNMP
    # OID tree: .1.3.6.1.4.1.9.9.719.1.9.35.1 with oids [32, 47, 43]
    # Map to:
    #   model = .1.3.6.1.4.1.9.9.719.1.9.35.1.32 (cucsComputeRackUnitModel)
    #   serial = .1.3.6.1.4.1.9.9.719.1.9.35.1.47 (cucsComputeRackUnitSerial)
    #   status = .1.3.6.1.4.1.9.9.719.1.9.35.1.43 (cucsComputeRackUnitOperability)
    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.9.9.719.1.9.35.1.32.0",
        ".1.3.6.1.4.1.9.9.719.1.9.35.1.47.0",
        ".1.3.6.1.4.1.9.9.719.1.9.35.1.43.0"
    ], mutates=False)

    # Parse snmpget output: format "OID = STRING: value"
    lines = res.stdout.splitlines()
    if len(lines) != 3:
        return {
            "changed": False,
            "msg": "unexpected SNMP output format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    values = []
    for line in lines:
        # Extract value after last ": "
        idx = line.rfind(": ")
        if idx == -1:
            return {
                "changed": False,
                "msg": "failed to parse SNMP line: " + line,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        val = line[idx + 2:].strip().strip('"')
        values.append(val)

    if len(values) < 3:
        return {
            "changed": False,
            "msg": "not enough SNMP values received",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    model = values[0]
    serial = values[1]
    status = values[2]

    # Map status code to state and readable text using MAP_OPERABILITY
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

    state_code, status_text = MAP_OPERABILITY.get(status, (3, "Unknown, status code " + str(status)))
    
    # Map state_code to Checkmk states:
    # 0 -> OK, 1 -> WARN, 2 -> CRIT
    if state_code == 0:
        state = "OK"
    elif state_code == 1:
        state = "WARN"
    else:
        state = "CRIT"

    return {
        "changed": False,
        "msg": "Status: %s, Model: %s, SN: %s" % (status_text, model, serial),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
