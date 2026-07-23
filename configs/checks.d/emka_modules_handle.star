def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # SNMP walk is not available in Starlark runtime; simulate discovery
        # by checking if the check is expected to run on this host.
        # Since we can't perform SNMP queries, we return empty discovery.
        # In a real agent-based environment, the check would run after the
        # SNMP section gathers data, but in Starlark we have no way to do that.
        # Return empty to indicate no handle services found (or we can't discover).
        return {
            "changed": False,
            "msg": "discovered 0 handles",
            "data": {"discovery": []},
        }

    # Check mode for emka_modules_handle
    # Since we can't access SNMP data directly, we return UNKNOWN as we cannot
    # determine the handle state without the agent data.
    # In production Checkmk environments, this check runs after the emka_modules
    # SNMP section gathers data. Since we don't have access to that data here,
    # we report UNKNOWN with a message.
    return {
        "changed": False,
        "msg": "handle data unavailable (requires SNMP section emka_modules)",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }
