def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: the Meraki Dashboard API is a cloud API
        # accessed via the Checkmk special agent on the monitoring server.
        # There is no local on-host data source for Meraki sensor readings.
        # The special agent's configuration/credentials would be stored
        # locally only in non-standard locations; we probe for a config file.
        config_paths = [
            "/etc/checkmk/meraki.conf",
            "/etc/checkmk.d/meraki.conf",
            "/etc/meraki/agent.conf",
        ]
        has_config = False
        for p in config_paths:
            if ctx.file_exists(p):
                has_config = True
                break

        if not has_config:
            # No Meraki API configuration present on this host -> the
            # Meraki cloud API is not accessible here. Absence is an answer.
            return {
                "changed": False,
                "msg": "no Meraki API configuration found; check does not apply",
                "data": {"discovery": []},
            }

        # Configuration exists but the Meraki Dashboard API is a cloud API
        # reachable only via HTTPS from the special agent. With only ctx.run
        # (no HTTP client) we cannot fetch live data. Report absence of data.
        return {
            "changed": False,
            "msg": "Meraki API configuration found but no local data source available; discovery empty",
            "data": {"discovery": []},
        }

    item = params.get("item", "")

    # Check mode: the Meraki sensor data comes from the cloud API, not from
    # any local file or command. Establish that the product is actually here.
    # Probe for a local data source — there is none for a cloud API.
    config_paths = [
        "/etc/checkmk/meraki.conf",
        "/etc/checkmk.d/meraki.conf",
        "/etc/meraki/agent.conf",
    ]
    has_config = False
    for p in config_paths:
        if ctx.file_exists(p):
            has_config = True
            break

    if not has_config:
        return {
            "changed": False,
            "msg": "no Meraki API configuration found; cannot retrieve sensor temperature",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Even with config, we cannot reach the cloud API from this runtime.
    # The Meraki Dashboard API is not a local data source.
    return {
        "changed": False,
        "msg": "Meraki Dashboard API is a cloud API; no local data source available for item " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }