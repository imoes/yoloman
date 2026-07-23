def main(ctx, params):
    # === Helper constants ===
    HA_MODES = {
        "0": "standalone",
        "1": "primary",
        "2": "secondary",
        "3": "unknown",
    }
    HEALTH_MAP = {
        "0": "unknown",
        "1": "initializing",
        "2": "down",
        "3": "functional",
        "4": "some HA monitored interfaces failed",
        "5": "monitorFail",
        "6": "monitorOK",
        "7": "all HA monitored interfaces failed",
        "8": "configured to listening mode (dumb)",
        "9": "HA status manually disabled",
        "10": "SSL card failed",
        "11": "route monitor has failed",
    }
    # Health to State mapping (WARN, CRIT, OK, UNKNOWN)
    HEALTH_TO_STATE = {
        "0": "WARN",   # UNKOWN
        "1": "WARN",   # INITIALIZING
        "2": "CRIT",   # DOWN
        "3": "OK",     # FUNCTIONAL
        "4": "CRIT",   # SOME_HA_MONITORED_INTERFACES_FAILED
        "5": "WARN",   # MONITOR_FAIL
        "6": "WARN",   # MONITOR_OK
        "7": "CRIT",   # ALL_HA_MONITORED_INTERFACES_FAILED
        "8": "WARN",   # CONFIGURED_LISTENING_MODE
        "9": "WARN",   # HA_STATUS_MANUALLY_DISABLED
        "10": "CRIT",  # SSL_CARD_FAILED
        "11": "CRIT",  # ROUTER_MONITORE_FAILED
    }

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discovery mode: walk HA OID subtree to determine mode
        base_oid = ".1.3.6.1.4.1.5951.4.1.1"
        # We need three OIDs: sysHighAvailabilityMode(6), haPeerState(23.3), haCurState(23.24)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.5951.4.1.1.6",  # sysHighAvailabilityMode
            ".1.3.6.1.4.1.5951.4.1.1.23.3",  # haPeerState
            ".1.3.6.1.4.1.5951.4.1.1.23.24",  # haCurState
        ], mutates=False)
        if res.rc != 0:
            # Agent unreachable or SNMP error -> no service
            return {"changed": False, "msg": "SNMP error", "data": {"discovery": []}}

        # Parse: OID = TYPE: value
        lines = res.stdout.splitlines()
        # We expect exactly 3 lines in the order: sysHighAvailabilityMode, haPeerState, haCurState
        if len(lines) < 3:
            return {"changed": False, "msg": "SNMP data incomplete", "data": {"discovery": []}}

        # Extract values: last part after last '=' and strip whitespace
        values = []
        for line in lines:
            parts = line.rsplit(" = ", 1)
            if len(parts) != 2:
                continue
            val = parts[1].strip()
            # Extract raw number from "INTEGER: 1"
            if val.startswith("INTEGER: "):
                val = val[len("INTEGER: "):]
            elif val.startswith("Gauge32: "):
                val = val[len("Gauge32: "):]
            elif val.startswith("Counter32: "):
                val = val[len("Counter32: "):]
            elif val.startswith("Timeticks: "):
                val = val[len("Timeticks: "):].strip("()").split(" ")[0]
            # Some implementations may just give number
            values.append(val)

        if len(values) < 3:
            return {"changed": False, "msg": "SNMP data incomplete", "data": {"discovery": []}}

        our_ha_mode = values[0]
        peer_ha_mode = values[1]
        our_health = values[2]

        mode_str = HA_MODES.get(our_ha_mode, "unknown")
        if mode_str == "standalone":
            # Standalone: do not create a service
            return {"changed": False, "msg": "discovered HA: standalone", "data": {"discovery": []}}

        # Otherwise: yield a service with params matching discovered mode
        params_out = {"failover_monitoring": ["disabled", None]}
        if mode_str in ["primary", "secondary", "unknown"]:
            params_out["discovered_failover_mode"] = mode_str

        return {
            "changed": False,
            "msg": "discovered HA: %s" % mode_str,
            "data": {"discovery": [{"item": "", "params": params_out, "metrics": []}]},
        }

    # === Check mode ===
    # Fetch SNMP values again
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.5951.4.1.1.6",  # sysHighAvailabilityMode
        ".1.3.6.1.4.1.5951.4.1.1.23.3",  # haPeerState
        ".1.3.6.1.4.1.5951.4.1.1.23.24",  # haCurState
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = res.stdout.splitlines()
    if len(lines) < 3:
        return {
            "changed": False,
            "msg": "SNMP data incomplete",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    values = []
    for line in lines:
        parts = line.rsplit(" = ", 1)
        if len(parts) != 2:
            continue
        val = parts[1].strip()
        if val.startswith("INTEGER: "):
            val = val[len("INTEGER: "):]
        elif val.startswith("Gauge32: "):
            val = val[len("Gauge32: "):]
        elif val.startswith("Counter32: "):
            val = val[len("Counter32: "):]
        elif val.startswith("Timeticks: "):
            val = val[len("Timeticks: "):].strip("()").split(" ")[0]
        values.append(val)

    if len(values) < 3:
        return {
            "changed": False,
            "msg": "SNMP data incomplete",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    our_ha_mode = values[0]
    peer_ha_mode = values[1]
    our_health = values[2]

    mode_str = HA_MODES.get(our_ha_mode, "unknown")
    peer_mode_str = HA_MODES.get(peer_ha_mode, "unknown")
    health_str = HEALTH_MAP.get(our_health, "unknown")

    # Build result list
    msgs = []
    state = "OK"

    # 1. Check our HA mode
    if mode_str == "standalone":
        # No service should exist, but if we are here, something is off -> UNKNOWN
        return {
            "changed": False,
            "msg": "HA mode: standalone (unexpected)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    elif mode_str == "unknown":
        msgs.append("Failover mode: unknown")
        state = "UNKNOWN"
    else:
        # Failover monitoring logic
        failover_conf = params.get("failover_monitoring", ["disabled", None])
        if failover_conf[0] == "disabled":
            msgs.append("Failover mode: %s" % mode_str)
        elif failover_conf[0] == "use_discovered_failover_mode":
            discovered_mode = params.get("discovered_failover_mode", None)
            if discovered_mode == None:
                msgs.append("Failover monitoring: discovered mode not available")
                state = "UNKNOWN"
            else:
                expected_mode = discovered_mode
                if mode_str != expected_mode:
                    msgs.append("Failover mode: %s, failover detected" % mode_str)
                    state = "CRIT"
                else:
                    msgs.append("Failover mode: %s" % mode_str)
        elif failover_conf[0] == "explicit_failover_mode":
            expected_mode = failover_conf[1]
            if mode_str == expected_mode:
                msgs.append("Failover mode: %s" % mode_str)
            else:
                msgs.append("Failover mode: %s, expected: %s" % (mode_str, expected_mode))
                state = "CRIT"
        else:
            # fallback
            msgs.append("Failover mode: %s" % mode_str)

    # 2. Check peer mode
    if peer_mode_str == "standalone":
        msgs.append("Peer failover mode: standalone")
        state = "WARN"
    elif peer_mode_str in ["primary", "secondary"]:
        msgs.append("Peer failover mode: %s" % peer_mode_str)
        if state == "OK":
            state = "OK"
    else:
        msgs.append("Peer failover mode: %s" % peer_mode_str)
        state = "WARN"

    # 3. Health
    health_state = HEALTH_TO_STATE.get(our_health, "WARN")
    if health_state == "CRIT" and state != "CRIT":
        state = "CRIT"
    elif health_state == "WARN" and state == "OK":
        state = "WARN"
    msgs.append("Health: %s" % health_str)

    return {
        "changed": False,
        "msg": ", ".join(msgs),
        "data": {"state": state, "metrics": {}, "details": ""},
    }