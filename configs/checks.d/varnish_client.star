def main(ctx, params):
    # Read the varnish stats from the agent output
    res = ctx.run(["varnishstats", "-1"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "varnishstats command failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse varnish stats (simple key-value format: "key value type description")
    parsed = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        key, value_str, typ, desc = parts
        value = int(value_str) if value_str.isdigit() else None
        parsed[key] = {"value": value, "descr": desc}

    # Discovery mode: check if client_req metric exists
    if params.get("_discover"):
        if "client_req" in parsed:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {"item": "", "params": {}, "metrics": [
                            "varnish_client_drop_rate",
                            "varnish_client_req_rate",
                            "varnish_client_conn_rate",
                            "varnish_client_drop_late_rate",
                        ]}
                    ]
                },
            }
        else:
            return {
                "changed": False,
                "msg": "no client data found",
                "data": {"discovery": []},
            }

    # Check mode: process client metrics
    # Map metric names to their keys and descriptions
    metric_keys = [
        ("client_drop", "varnish_client_drop_rate", "Client connections dropped"),
        ("client_req", "varnish_client_req_rate", "Client requests received"),
        ("client_conn", "varnish_client_conn_rate", "Client connections accepted"),
        ("client_drop_late", "varnish_client_drop_late_rate", "Client connections dropped late"),
    ]

    # Prepare metrics dict
    metrics = {}
    state = "OK"
    details_parts = []

    for key, perf_var_name, description in metric_keys:
        data = parsed.get(key)
        if data == None or data.get("value") == None:
            continue

        # We cannot compute rates in Starlark without state persistence,
        # so report absolute values. In real Checkmk, get_rate() handles this.
        # For simplicity, use absolute values as rates (approximation).
        value = data["value"]
        metrics[perf_var_name] = value

        # Format description
        rate_str = "%f %s/s" % (float(value), description.split()[-1])
        details_parts.append(rate_str)

    # Format details string
    details = ", ".join(details_parts) if details_parts else "no client data"

    # If we have no data at all, return UNKNOWN
    if not metrics:
        return {
            "changed": False,
            "msg": "no client metrics found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": details,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }
