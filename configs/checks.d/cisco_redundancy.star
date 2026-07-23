# ===== Starlark check: cisco_redundancy =====
# Redundancy Framework Status — SNMP-based, read-only

def main(ctx, params):
    # SNMP OIDs from the Checkmk source
    base_oid = ".1.3.6.1.4.1.9.9.176.1.1"
    oids = ["1.0", "2.0", "3.0", "4.0", "6.0", "8.0"]  # cRFStatusUnitId, UnitState, PeerUnitId, PeerUnitState, DuplexMode, LastSwactReasonCode

    # Build snmpget commands for each OID (scalar, so single-instance)
    res_list = []
    for oid in oids:
        full_oid = base_oid + "." + oid
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), full_oid], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP error: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        res_list.append(res.stdout.strip())

    # Parse each line: "<OID> = <TYPE>: <value>"
    def parse_snmp_line(line):
        # Example: ".1.3.6.1.4.1.9.9.176.1.1.2.0 = INTEGER: 14"
        # Split on last '=' and strip spaces
        parts = line.rsplit("=", 1)
        if len(parts) != 2:
            return ""
        val = parts[1].strip()
        # Extract value after type (e.g., "INTEGER: 14" -> "14")
        if ":" in val:
            val = val.split(":", 1)[1].strip()
        return val

    values = [parse_snmp_line(line) for line in res_list]
    if len(values) != 6 or "" in values:
        return {
            "changed": False,
            "msg": "SNMP data incomplete or unparseable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map states as in Checkmk source
    map_states = {
        "unit_state": {
            "0": "not found",
            "1": "not known",
            "2": "disabled",
            "3": "initialization",
            "4": "negotiation",
            "5": "standby cold",
            "6": "standby cold config",
            "7": "standby cold file sys",
            "8": "standby cold bulk",
            "9": "standby hot",
            "10": "active fast",
            "11": "active drain",
            "12": "active pre-config",
            "13": "active post-config",
            "14": "active",
            "15": "active extra load",
            "16": "active handback",
        },
        "duplex_mode": {
            "2": "False (SUB-Peer not detected)",
            "1": "True (SUB-Peer detected)",
        },
        "swact_reason": {
            "1": "unsupported",
            "2": "none",
            "3": "not known",
            "4": "user initiated",
            "5": "user forced",
            "6": "active unit failed",
            "7": "active unit removed",
            "8": "active lost gateway connectivity",
            "9": "RMI port went down on active",
        },
    }

    # Extract fields
    unit_id = values[0]
    unit_state = values[1]
    peer_id = values[2]
    peer_state = values[3]
    duplex_mode = values[4]
    swact_reason = values[5]

    # Discovery logic: yield service only if last swact reason code != "1"
    # (checkmk discovery yields service only if swact_reason != "1")
    # But in check mode we assume service exists (discovery happened elsewhere)
    # For check mode, proceed with current values.

    # Build infotexts for current and init states
    # Note: Checkmk stores init_states in params, default empty list
    init_states = params.get("init_states", ["0", "0", "0", "0", "0"])

    # Current state info
    unit_state_name = map_states["unit_state"].get(unit_state, "unknown")
    peer_state_name = map_states["unit_state"].get(peer_state, "unknown")
    duplex_name = map_states["duplex_mode"].get(duplex_mode, "unknown")
    now_text = "Unit ID: {} ({}), Peer ID: {} ({}), Duplex mode: {}".format(
        unit_id, unit_state_name, peer_id, peer_state_name, duplex_name
    )

    # Init state info (only if init_states present)
    if len(init_states) >= 5:
        init_unit_state = init_states[0]
        init_peer_state = init_states[3]
        init_unit_state_name = map_states["unit_state"].get(init_unit_state, "unknown")
        init_peer_state_name = map_states["unit_state"].get(init_peer_state, "unknown")
        init_duplex_mode = init_states[4]
        init_duplex_name = map_states["duplex_mode"].get(init_duplex_mode, "unknown")
        init_text = "Unit ID: {} ({}), Peer ID: {} ({}), Duplex mode: {}".format(
            init_states[0], init_unit_state_name,
            init_states[2], init_peer_state_name,
            init_duplex_name
        )
    else:
        init_text = ""

    # Determine state
    state = "OK"
    if init_states != values[:5]:
        # Switchover happened
        # Check states: WARN if active/standby/hot/active, else CRIT
        if (unit_state in ["2", "9", "14"] or peer_state in ["2", "9", "14"]):
            state = "WARN"
        else:
            state = "CRIT"

        infotext = "Switchover - Old status: {}, New status: {}".format(init_text, now_text)
    else:
        # No switchover
        infotext = "{}, Last swact reason code: {}".format(now_text, map_states["swact_reason"].get(swact_reason, "unknown"))

    # Peer state "1" (not known) → CRIT always
    if peer_state == "1":
        state = "CRIT"

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        },
    }
