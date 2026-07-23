# Map of operational states
_OPER_STATE_MAP = {
    1: "running normally",
    2: "not running",
    3: "currently starting",
    4: "currently stopping",
    5: "fault",
}

# SNMP base OID for bluecat_dns
_BLUECAT_DNS_BASE_OID = ".1.3.6.1.4.1.13315.3.1.2.2.1"
_BLUECAT_DNS_OPER_STATE_OID = _BLUECAT_DNS_BASE_OID + ".1"

def _get_service_name(params):
    # For DNS check, service_name is always "DNS" since leases is not exposed in this section
    return "DNS"

def _parse_oper_state(oper_state_str):
    if oper_state_str == None or not oper_state_str.strip():
        return None
    val = oper_state_str.strip()
    if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
        return int(val)
    return None

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: yield a single Service() as per the check source
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"oper_states": {"warning": [2, 3, 4], "critical": [5]}}, "metrics": []}]},
        }

    # Check mode: get operational state via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch DnsSerOperState (OID .1.3.6.1.4.1.13315.3.1.2.2.1.1)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        _BLUECAT_DNS_OPER_STATE_OID
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse output: "OID = INTEGER: <value>"
    oper_state = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        if value_part.startswith("INTEGER: "):
            oper_state_str = value_part[9:]  # remove "INTEGER: "
            oper_state = _parse_oper_state(oper_state_str)
            break

    if oper_state == None:
        return {
            "changed": False,
            "msg": "no operational state found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get params
    warn_states = params.get("oper_states", {}).get("warning", [2, 3, 4])
    crit_states = params.get("oper_states", {}).get("critical", [5])

    # Determine state
    state = "OK"
    if oper_state in warn_states:
        state = "WARN"
    elif oper_state in crit_states:
        state = "CRIT"

    service_name = _get_service_name(params)
    summary = "%s is %s" % (service_name, _OPER_STATE_MAP.get(oper_state, "unknown state (%d)" % oper_state))

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        },
    }
