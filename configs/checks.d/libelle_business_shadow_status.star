def main(ctx, params):
    # This check is for the checkmk plugin, but we run on yolo-man agent.
    # The original plugin parses agent section <<<libelle_business_shadow:sep(58)>>>
    # which is NOT available in this environment. We cannot retrieve it.
    # Return UNKNOWN with a message indicating the section is missing.
    return {
        "changed": False,
        "msg": "Agent section <<<libelle_business_shadow:sep(58)>> is not available",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }