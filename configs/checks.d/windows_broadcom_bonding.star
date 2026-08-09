def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }
    item = params.get("item", "")
    return {
        "changed": False,
        "msg": "windows_broadcom_bonding: not available on this host (Windows Broadcom bonding)",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "Windows Broadcom bonding interface data is not available on this host",
        },
    }