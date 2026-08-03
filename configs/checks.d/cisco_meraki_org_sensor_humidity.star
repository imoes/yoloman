def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe: is the Meraki cloud reachable / does the sensor report humidity?
    # Meraki sensors report via the Meraki dashboard API; the agent-based section
    # is populated by a special agent (cisco_meraki_org_sensor_readings). On this
    # host we have no Checkmk special agent, so we cannot gather real data.
    # Per the translation contract: absence is an answer. We must not invent a
    # data source. The product (Meraki cloud API / special agent) is not present
    # on this host, so we report absence rather than OK.

    if params.get("_discover"):
        # No on-host source for the Meraki sensor readings section -> nothing to
        # discover here. This check only makes sense where the special agent runs.
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    return {
        "changed": False,
        "msg": "no Cisco Meraki sensor readings available on this host (no special agent)",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }