def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"levels_upper": ("fixed", (60, 80))}, "metrics": ["utilization"]}]}
        }

    # Check mode: gather appliance performance data from agent section
    # The agent section expects data like: <<<cisco_meraki_org_appliance_performance:sep(0)>>>
    # and outputs JSON array like [{"perfScore": 45}]
    # We simulate reading the agent section by running the equivalent command.
    # In practice, the yolo-man agent would provide this via a built-in, but here we
    # must run a command equivalent to what the Checkmk agent would run.
    # Since this is a Checkmk plugin for Cisco Meraki, the data comes from the
    # Meraki API, which the agent accesses via API calls. The yolo-man agent
    # does not have Meraki API integration, so this check cannot be meaningfully
    # implemented as a pure read-only check without external APIs.

    # However, per the instructions, we translate the check to run on OUR agent.
    # The original Checkmk agent section reads from a JSON payload in the agent output.
    # The yolo-man agent doesn't have that agent output, but we can assume the agent
    # section would be provided via a built-in (e.g., ctx.agent_section()).
    # Since ctx.* does not include agent_section(), we cannot access that data here.

    # The check must fail if data is not available, per Checkmk semantics:
    # "UNKNOWN" state if section is missing.

    # For the sake of producing a valid Starlark module that matches the contract,
    # we assume the agent section data is provided as a file or via a command.
    # The original Checkmk agent section is named "cisco_meraki_org_appliance_performance".
    # Let's assume a placeholder file exists at /var/lib/cmk-agent/cisco_meraki_org_appliance_performance.
    # This is NOT a real path, so the check should not rely on it.

    # Since the original check expects JSON data from the Meraki API (not a local file),
    # and we have no way to fetch Meraki data without the API credentials,
    # the only realistic fallback is to return UNKNOWN.

    # But per the contract: "Data ungatherable / item gone -> state 'UNKNOWN' with an explaining msg".
    return {
        "changed": False,
        "msg": "Appliance performance data unavailable (requires Cisco Meraki API access)",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }