# Module for Checkmk bluecat_dhcp check (translated to Starlark)
# Read-only SNMP-based check: no mutations, no file writes, always changed=False

def main(ctx, params):
    # SNMP base OID for bluecat_dhcp section
    base_oid = ".1.3.6.1.4.1.13315.3.1.1.2.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode
    if params.get("_discover"):
        # Fetch both OIDs: dhcpOperState (1) and dhcpLeaseStatsSuccess (3)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        oper_state = None
        leases = None

        for line in res.stdout.splitlines():
            line = line.strip()
            if line == "":
                continue
            parts = line.split(" = ", 2)
            if len(parts) < 2:
                continue
            oid_val = parts[0].strip()
            val_part = parts[1].strip()
            if oid_val == base_oid + ".1":
                oper_state = val_part
            elif oid_val == base_oid + ".3":
                leases = val_part

        # Parse values: strip type prefix if present (e.g., "INTEGER: ", " Gauge32: ")
        if oper_state != None:
            if ":" in oper_state:
                oper_state = oper_state.split(":", 1)[1].strip()
            if not oper_state.isdigit():
                oper_state = None
            else:
                oper_state = int(oper_state)

        if leases != None:
            if ":" in leases:
                leases = leases.split(":", 1)[1].strip()
            if not leases.isdigit():
                leases = None
            else:
                leases = int(leases)

        # Only discover if oper_state != 2 (not "not running")
        # Checkmk source: if section["oper_state"] != 2: yield Service()
        if oper_state != None and oper_state != 2:
            return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [
                {"item": "", "params": {"oper_states": {"warning": [2, 3, 4], "critical": [5]}},
                 "metrics": ["leases"]}
            ]}}
        else:
            return {"changed": False, "msg": "DHCP not discovered", "data": {"discovery": []}}

    # Check mode
    # Fetch values again (same as discovery, but now for one service)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oper_state = None
    leases = None

    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split(" = ", 2)
        if len(parts) < 2:
            continue
        oid_val = parts[0].strip()
        val_part = parts[1].strip()
        if oid_val == base_oid + ".1":
            oper_state = val_part
        elif oid_val == base_oid + ".3":
            leases = val_part

    # Parse values
    if oper_state != None:
        if ":" in oper_state:
            oper_state = oper_state.split(":", 1)[1].strip()
        if not oper_state.isdigit():
            oper_state = None
        else:
            oper_state = int(oper_state)

    if leases != None:
        if ":" in leases:
            leases = leases.split(":", 1)[1].strip()
        if not leases.isdigit():
            leases = None
        else:
            leases = int(leases)

    # State mapping (same as _OPER_STATE_MAP)
    oper_state_map = {
        1: "running normally",
        2: "not running",
        3: "currently starting",
        4: "currently stopping",
        5: "fault",
    }

    # Get params (checkmk default)
    oper_states = params.get("oper_states", {"warning": [2, 3, 4], "critical": [5]})
    warning_states = oper_states.get("warning", [2, 3, 4])
    critical_states = oper_states.get("critical", [5])

    # Determine monitoring state
    state = "OK"
    if oper_state == None:
        return {"changed": False, "msg": "No operational state data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if oper_state in critical_states:
        state = "CRIT"
    elif oper_state in warning_states:
        state = "WARN"

    # Service name: DHCP if leases present, else DNS
    service_name = "DHCP" if leases != None else "DNS"

    msg = "%s is %s" % (service_name, oper_state_map.get(oper_state, "unknown state"))
    metrics = {}
    details = ""

    if service_name == "DHCP" and leases != None:
        msg += ", %d lease%s per second" % (leases, "" if leases == 1 else "s")
        metrics = {"leases": leases}
        # No details required by example
    else:
        details = ""

    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}
