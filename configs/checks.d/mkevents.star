# Starlark check module: checkmk.mkevents
# Read-only: no mutations, only reporting.

def main(ctx, params):
    # This check is a server-side active check definition translator.
    # It does NOT gather runtime data; it only validates parameters and
    # reports a synthetic service status for discovery.
    #
    # In Checkmk, this plugin defines how the active check command is built.
    # For Starlark, we simulate discovery by returning one item with item=""
    # (single-service check) and a dummy metrics map.
    #
    # Since this is read-only and there is no actual runtime data to gather,
    # we return OK state with a message indicating the check is configured.

    # Discovery mode: return single item (no per-resource breakdown)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]
            },
        }

    # Check mode (normal call for one item)
    return {
        "changed": False,
        "msg": "mkevents active check is configured",
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }
