# State mapping: SNMP integer -> (state, description)
_OCTOPUS_STATES_MAP = {
    1: ("OK", "normal"),
    2: ("WARN", "warning"),
    3: ("WARN", "minor"),
    4: ("CRIT", "major"),
    5: ("CRIT", "critical"),
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Check if system matches detection rule: .1.3.6.1.2.1.1.1.0 contains "agent for hipath"
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if "agent for hipath" in res.stdout:
            return {
                "changed": False,
                "msg": "discovered Global status service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
            }
        else:
            return {
                "changed": False,
                "msg": "system does not match detection rule",
                "data": {"discovery": []}
            }

    # Check mode: fetch current Octopus status from SNMP
    # OID: .1.3.6.1.4.1.231.7.2.9.1.1.0
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.231.7.2.9.1.1.0"], mutates=False)
    
    # Parse the response: expected format "iso.3.6.1.4.1.231.7.2.9.1.1.0 = INTEGER: X"
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Unable to retrieve Octopus status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract integer value from output
    line = res.stdout.strip()
    # Find " = INTEGER: " part
    idx = line.find(" = INTEGER: ")
    if idx == -1:
        return {
            "changed": False,
            "msg": "Unexpected SNMP response format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    value_str = line[idx + len(" = INTEGER: "):].strip()
    
    # Guard against non-integer values
    if not value_str:
        return {
            "changed": False,
            "msg": "Empty SNMP value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check if string represents a valid integer
    valid = True
    i = 0
    if value_str.startswith("-"):
        i = 1
    if i >= len(value_str):
        valid = False
    while i < len(value_str):
        c = value_str[i]
        if c < '0' or c > '9':
            valid = False
            break
        i = i + 1
    
    if not valid:
        return {
            "changed": False,
            "msg": "SNMP value not an integer: " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    octopus_state = int(value_str)

    # Look up state and description
    if octopus_state not in _OCTOPUS_STATES_MAP:
        return {
            "changed": False,
            "msg": "Unknown Octopus state: " + str(octopus_state),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state, desc = _OCTOPUS_STATES_MAP[octopus_state]
    msg = "PBX system state is " + desc
    if octopus_state >= 3:
        msg += " error"

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
