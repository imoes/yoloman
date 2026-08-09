# ScaleIO SDS status check (read-only Starlark translation of checkmk.scaleio_sds_status)

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: ScaleIO SDS data comes from the Checkmk
        # agent section scaleio_sds, which this runtime does not have.
        # There is no on-host source we can substitute for an appliance API or
        # another product agent output. Absence -> empty discovery.
        return {
            "changed": False,
            "msg": "discovered 0 ScaleIO SDS instances",
            "data": {"discovery": []},
        }

    item = params.get("item", "")

    # No on-host ScaleIO SDS status source exists here; the data is gathered
    # by the Checkmk agent plugin which is not present in this runtime.
    # NEVER substitute local /proc or /sys for an appliance database.
    msg = "ScaleIO SDS status not available: no on-host scaleio_sds data source"
    if item:
        msg = msg + " for item " + item
    details = "ScaleIO is a storage appliance; its SDS status data is gathered by the Checkmk agent plugin over the appliance API, which is not present on this host."
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": details,
        },
    }