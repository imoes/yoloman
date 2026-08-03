HA_MODE_MAP = {
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

HEALTH_TO_STATE = {
    "0": "WARN",
    "1": "WARN",
    "2": "CRIT",
    "3": "OK",
    "4": "CRIT",
    "5": "WARN",
    "6": "WARN",
    "7": "CRIT",
    "8": "WARN",
    "9": "WARN",
    "10": "CRIT",
    "11": "CRIT",
}

BASE_OID_MODE = ".1.3.6.1.4.1.5951.4.1.1.6"
BASE_OID_PEER = ".1.3.6.1.4.1.5951.4.1.1.23.3"
BASE_OID_HEALTH = ".1.3.6.1.4.1.5951.4.1.1.23.24"


def _get_snmp_value(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        if res.rc == 127:
            fail("snmpget is not installed on the host")
        return None
    val = res.stdout.strip()
    if val == "":
        return None
    return val


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        our_mode = _get_snmp_value(ctx, host, community, BASE_OID_MODE)
        if our_mode == None or our_mode == "0":
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        peer_mode = _get_snmp_value(ctx, host, community, BASE_OID_PEER)
        if peer_mode == None:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        our_ha_readable = HA_MODE_MAP.get(our_mode, "unknown")
        if our_ha_readable == "standalone" or our_ha_readable == "unknown":
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        discovered_mode = our_ha_readable
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "HA Node Status",
                        "params": {
                            "discovered_failover_mode": discovered_mode,
                            "failover_monitoring": "disabled",
                        },
                        "metrics": [],
                    }
                ]
            },
        }

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    our_mode = _get_snmp_value(ctx, host, community, BASE_OID_MODE)
    if our_mode == None:
        return {
            "changed": False,
            "msg": "Could not retrieve HA mode via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    our_ha_readable = HA_MODE_MAP.get(our_mode, "unknown")
    if our_ha_readable == "standalone":
        return {
            "changed": False,
            "msg": "Node is in standalone mode",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    peer_mode = _get_snmp_value(ctx, host, community, BASE_OID_PEER)
    if peer_mode == None:
        return {
            "changed": False,
            "msg": "Could not retrieve peer HA mode via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    peer_ha_readable = HA_MODE_MAP.get(peer_mode, "unknown")
    if peer_ha_readable == "standalone":
        return {
            "changed": False,
            "msg": "Peer is in standalone mode",
            "data": {"state": "WARN", "metrics": {}, "details": ""},
        }

    our_health_raw = _get_snmp_value(ctx, host, community, BASE_OID_HEALTH)
    if our_health_raw == None:
        return {
            "changed": False,
            "msg": "Could not retrieve HA health via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    health_state = HEALTH_TO_STATE.get(our_health_raw, "WARN")
    health_readable = HEALTH_MAP.get(our_health_raw, "unknown")

    summaries = []
    states = []

    if our_ha_readable != "unknown":
        summaries.append("Failover mode: %s" % our_ha_readable)
        states.append("OK")

    if peer_ha_readable in ("primary", "secondary"):
        summaries.append("Peer failover mode: %s" % peer_ha_readable)
        states.append("OK")
    else:
        summaries.append("Peer failover mode: %s" % peer_ha_readable)
        states.append("WARN")

    summaries.append("Health: %s" % health_readable)
    states.append(health_state)

    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": ", ".join(summaries),
        "data": {"state": state, "metrics": {}, "details": ""},
    }