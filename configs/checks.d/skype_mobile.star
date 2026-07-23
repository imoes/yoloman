# checkmk.skype_mobile — Read-only Starlark check module for Skype Mobile Sessions

def _check_levels_upper(levels):
    if levels == None:
        return None
    return levels.get("upper")

def _check_levels(value, levels_upper):
    if levels_upper == None:
        return "OK", value
    warn, crit = levels_upper
    if value >= crit:
        return "CRIT", value
    if value >= warn:
        return "WARN", value
    return "OK", value

def main(ctx, params):
    if params.get("_discover"):
        # Discover items from WMI tables
        tables = ["LS:WEB - UCWA", "LS:WEB - Throttling and Authentication"]
        # We simulate inventory_wmi_table_total for these tables
        # Since we cannot query WMI directly, we return a single item
        # assuming the tables exist (as the discovery would).
        # In a real agent plugin, ctx.run would fetch WMI data first.
        # For discovery, we rely on the presence of agent sections.
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "requests_processing": {"upper": (10000.0, 20000.0)}
                        },
                        "metrics": [
                            "ucwa_active_sessions_android",
                            "ucwa_active_sessions_ipad",
                            "ucwa_active_sessions_iphone",
                            "ucwa_active_sessions_mac",
                            "web_requests_processing"
                        ]
                    }
                ]
            }
        }

    # Check mode for the single item (item is always "" for this check)
    # We do not actually query WMI; the agent already provides the skype section.
    # The Starlark runtime expects the agent output to be available as structured data.
    # Since we cannot access the parsed WMI section here, we simulate a realistic check
    # by returning UNKNOWN if we cannot determine the values — the real integration would
    # pass the parsed section via ctx (not available in this stub context).
    # As per the contract, we must return a valid verdict even in the absence of data.
    # We assume the check is for the 'Skype Web Components' service and mimic the discovery.

    # Simulate values from WMI (for demonstration — real values would be in agent output)
    # In a real integration, ctx.run would execute a WMI query or the parsed section would be passed.
    # Here we return UNKNOWN since we cannot read WMI directly in Starlark.

    return {
        "changed": False,
        "msg": "Skype Mobile Sessions: UNKNOWN — no data",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "Agent data not available or section missing."
        }
    }
