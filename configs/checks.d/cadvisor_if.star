def main(ctx, params):
    # cAdvisor is a separate product exposing metrics via its HTTP API.
    # If it is not running on this host, the check does not apply.
    res = ctx.run(["curl", "-fs", "http://localhost:8080/api/v1.3/machine"], mutates=False)
    if res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "cAdvisor not reachable",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "cAdvisor not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # cAdvisor exposes per-interface network stats under /api/v1.3/stats
    stats = ctx.run(["curl", "-fs", "http://localhost:8080/api/v1.3/stats"], mutates=False)
    if stats.rc != 0 or not stats.stdout:
        if params.get("_discover"):
            return {"changed": False, "msg": "cAdvisor stats not reachable",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "cAdvisor stats not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(stats.stdout)

    if params.get("_discover"):
        # cAdvisor groups all interfaces under a single "Summary" service.
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "Summary", "params": {},
                     "metrics": ["in_octets", "out_octets", "in_errors",
                                 "out_errors", "in_discards", "out_discards"]},
                ]}}

    item = params.get("item", "Summary")
    if item != "Summary":
        return {"changed": False, "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Aggregate counters across all interfaces in the stats payload.
    in_total = 0.0
    out_total = 0.0
    in_err = 0.0
    out_err = 0.0
    in_disc = 0.0
    out_disc = 0.0

    for dev in data:
        networks = dev.get("networks")
        if networks == None:
            continue
        if type(networks) == "dict":
            iface_list = [networks]
        elif type(networks) == "list":
            iface_list = networks
        else:
            iface_list = []
        for iface in iface_list:
            in_total += float(iface.get("rx_bytes", 0))
            out_total += float(iface.get("tx_bytes", 0))
            in_err += float(iface.get("rx_errors", 0))
            out_err += float(iface.get("tx_errors", 0))
            in_disc += float(iface.get("rx_dropped", 0))
            out_disc += float(iface.get("tx_dropped", 0))

    metrics = {
        "in_octets": in_total,
        "out_octets": out_total,
        "in_errors": in_err,
        "out_errors": out_err,
        "in_discards": in_disc,
        "out_discards": out_disc,
    }

    msg = "Summary - in: %d, out: %d, in_err: %d, out_err: %d" % (
        in_total, out_total, in_err, out_err)
    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": metrics, "details": ""}}