def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {},
                    "metrics": ["n_events"],
                },
            ]},
        }

    return {
        "changed": False,
        "msg": "Datadog events data unavailable: requires Datadog special agent output",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "The datadog_events check relies on the datadog_events agent section produced by the Checkmk Datadog special agent. That agent queries the Datadog API and is not present in this runtime.",
        },
    }