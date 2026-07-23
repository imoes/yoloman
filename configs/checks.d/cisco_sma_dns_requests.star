# Constants for SNMP OIDs
OID_OUTSTANDING = ".1.3.6.1.4.1.15497.1.1.1.15.0"
OID_PENDING = ".1.3.6.1.4.1.15497.1.1.1.16.0"

def main(ctx, params):
    # Discovery mode: always yield one service for this check
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["pending_dns_requests", "outstanding_dns_requests"]}]}
        }

    # Check mode: gather data via SNMP
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn_pending = params.get("pending_dns_levels", ("no_levels", None))
    crit_pending = params.get("pending_dns_levels", ("no_levels", None))
    warn_outstanding = params.get("outstanding_dns_levels", ("no_levels", None))
    crit_outstanding = params.get("outstanding_dns_levels", ("no_levels", None))

    # Extract levels - only "no_levels" or ("fixed", value) are supported by default
    # For "no_levels", levels are None
    pending_levels = warn_pending[1] if warn_pending[0] == "fixed" else None
    outstanding_levels = warn_outstanding[1] if warn_outstanding[0] == "fixed" else None

    # Get SNMP values
    outstanding_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, OID_OUTSTANDING], mutates=False)
    if outstanding_res.rc != 0:
        return {"changed": False, "msg": "SNMP error fetching outstanding DNS requests",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    pending_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, OID_PENDING], mutates=False)
    if pending_res.rc != 0:
        return {"changed": False, "msg": "SNMP error fetching pending DNS requests",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse SNMP output: "OID = INTEGER: value"
    outstanding = None
    for line in outstanding_res.stdout.splitlines():
        if line and line.strip():
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                value_str = parts[1].strip()
                # Handle both "INTEGER: 123" and "123"
                if value_str.startswith("INTEGER: "):
                    value_str = value_str[9:]
                if value_str.isdigit():
                    outstanding = int(value_str)
                    break

    pending = None
    for line in pending_res.stdout.splitlines():
        if line and line.strip():
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                value_str = parts[1].strip()
                if value_str.startswith("INTEGER: "):
                    value_str = value_str[9:]
                if value_str.isdigit():
                    pending = int(value_str)
                    break

    # Handle missing values
    if outstanding == None or pending == None:
        return {"changed": False, "msg": "Could not parse DNS request values from SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Determine states
    # For "no_levels", always OK. For fixed levels, use standard upper bound logic.
    state = "OK"

    # Pending DNS requests check
    if pending_levels != None:
        if pending >= pending_levels:
            state = "CRIT"
        elif pending >= warn_pending[1] if warn_pending[0] == "fixed" else 0:
            if state != "CRIT":
                state = "WARN"
    # Outstanding DNS requests check
    if outstanding_levels != None:
        if outstanding >= outstanding_levels:
            state = "CRIT"
        elif outstanding >= warn_outstanding[1] if warn_outstanding[0] == "fixed" else 0:
            if state != "CRIT":
                state = "WARN"

    # Format message
    msg = "Pending: %d, Outstanding: %d" % (pending, outstanding)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"pending_dns_requests": pending, "outstanding_dns_requests": outstanding},
            "details": ""
        }
    }
