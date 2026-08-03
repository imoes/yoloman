def main(ctx, params):
    service_description = params.get("service_description", "Mail Delivery")
    fetch = params.get("fetch", {})
    connect_timeout = params.get("connect_timeout")
    forward = params.get("forward")

    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "no items",
            "data": {"discovery": []},
        }

    return {
        "changed": False,
        "msg": "check mail is an active check that sends test emails; no on-host mail service to monitor",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }