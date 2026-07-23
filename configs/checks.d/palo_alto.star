def main(ctx, params):
    # Discovery mode: always yield one service for Palo Alto devices
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode: read Palo Alto SNMP data
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.25461.2.1.2.1.1",   # panSysSwVersion
        ".1.3.6.1.4.1.25461.2.1.2.1.11",  # panSysHAState
        ".1.3.6.1.4.1.25461.2.1.2.1.12",  # panSysHAPeerState
        ".1.3.6.1.4.1.25461.2.1.2.1.13"   # panSysHAMode
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + (res.stderr if res.stderr else "unknown"),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    # Parse SNMP output: OID = TYPE: VALUE
    data = {}
    for line in lines:
        if " = " not in line:
            continue
        oid_part, value_part = line.strip().rsplit(" = ", 1)
        oid_num = oid_part.rsplit(".", 1)[-1]
        # Strip type prefix (INTEGER:, STRING:, etc.) and quotes
        if ": " in value_part:
            value = value_part.split(": ", 1)[1].strip().strip('"')
        else:
            value = value_part.strip()
        data[oid_num] = value

    # Check required fields exist
    if "1" not in data or "11" not in data or "12" not in data or "13" not in data:
        return {
            "changed": False,
            "msg": "Missing Palo Alto SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    firmware_version = data["1"]
    ha_local_state = data["11"]
    ha_peer_state = data["12"]
    ha_mode = data["13"]

    # State mapping as defined in Checkmk source
    STATE_MAPPING_DEFAULT = {
        "mode_disabled": 0,  # OK
        "mode_active_active": 0,  # OK
        "mode_active_passive": 0,  # OK
        "ha_local_state_active": 0,  # OK
        "ha_local_state_passive": 0,  # OK
        "ha_local_state_active_primary": 0,  # OK
        "ha_local_state_active_secondary": 0,  # OK
        "ha_local_state_disabled": 0,  # OK
        "ha_local_state_initial": 1,  # WARN
        "ha_local_state_tentative": 1,  # WARN
        "ha_local_state_non_functional": 2,  # CRIT
        "ha_local_state_suspended": 2,  # CRIT
        "ha_local_state_unknown": 3,  # UNKNOWN
        "ha_peer_state_active": 0,  # OK
        "ha_peer_state_passive": 0,  # OK
        "ha_peer_state_active_primary": 0,  # OK
        "ha_peer_state_active_secondary": 0,  # OK
        "ha_peer_state_disabled": 0,  # OK
        "ha_peer_state_initial": 1,  # WARN
        "ha_peer_state_tentative": 1,  # WARN
        "ha_peer_state_non_functional": 2,  # CRIT
        "ha_peer_state_suspended": 2,  # CRIT
        "ha_peer_state_unknown": 3,  # UNKNOWN
    }

    # Uniform format helper: lower + replace '-' with '_'
    def _uniform_format(name):
        return name.lower().replace("-", "_")

    # Build summary messages
    summaries = []
    
    # Firmware version line
    summaries.append("Firmware Version: " + firmware_version)
    
    # HA mode state
    mode_key = "mode_" + _uniform_format(ha_mode)
    mode_state = STATE_MAPPING_DEFAULT.get(mode_key, 3)  # Default to UNKNOWN if not found
    
    # HA local state
    if ha_mode == "disabled":
        local_state = 0  # OK
    else:
        local_key = "ha_local_state_" + _uniform_format(ha_local_state)
        local_state = STATE_MAPPING_DEFAULT.get(local_key, 3)  # Default to UNKNOWN
    
    # HA peer state
    if ha_mode == "disabled":
        peer_state = 0  # OK
    else:
        peer_key = "ha_peer_state_" + _uniform_format(ha_peer_state)
        peer_state = STATE_MAPPING_DEFAULT.get(peer_key, 3)  # Default to UNKNOWN

    # Determine overall state (worst of all)
    state = "OK"
    if mode_state == 2 or local_state == 2 or peer_state == 2:
        state = "CRIT"
    elif mode_state == 1 or local_state == 1 or peer_state == 1:
        state = "WARN"
    elif mode_state == 3 or local_state == 3 or peer_state == 3:
        state = "UNKNOWN"

    # Build summary string
    ha_mode_summary = "HA mode: " + ha_mode
    ha_local_summary = "HA local state: " + ha_local_state
    ha_peer_summary = "HA peer state: " + ha_peer_state
    
    # Final message format (Checkmk style)
    msg_parts = summaries + [ha_mode_summary, ha_local_summary]
    
    # Details (notice only for peer state)
    details = ""
    if ha_peer_summary:
        details = ha_peer_summary

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {},
            "details": details
        }
    }