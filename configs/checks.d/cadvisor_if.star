PROM_TO_METRIC = {
    "container_network_receive_bytes_total": "in",
    "container_network_receive_packets_dropped_total": "indisc",
    "container_network_receive_errors_total": "inerr",
    "container_network_transmit_bytes_total": "out",
    "container_network_transmit_packets_dropped_total": "outdisc",
    "container_network_transmit_errors_total": "outerr",
}


def _parse_prom(text):
    totals = {"in": 0.0, "out": 0.0, "inerr": 0.0, "outerr": 0.0, "indisc": 0.0, "outdisc": 0.0}
    for line in text.splitlines():
        if line.startswith("#") or len(line) == 0:
            continue
        brace = line.find("{")
        space = line.find(" ")
        if brace >= 0:
            name = line[:brace]
        elif space >= 0:
            name = line[:space]
        else:
            continue
        if name not in PROM_TO_METRIC:
            continue
        end_brace = line.find("}")
        if end_brace >= 0:
            rest = line[end_brace + 1:].strip()
        elif space >= 0:
            rest = line[space:].strip()
        else:
            continue
        parts = rest.split()
        if len(parts) == 0:
            continue
        val_str = parts[0]
        if val_str in ("NaN", "+Inf", "-Inf", "Inf"):
            continue
        first = val_str[0] if len(val_str) > 0 else ""
        if not (first.isdigit() or first == "-" or first == "+"):
            continue
        key = PROM_TO_METRIC[name]
        totals[key] = totals[key] + float(val_str)
    return totals


def main(ctx, params):
    host = params.get("host", "localhost")
    port = int(params.get("port", 8080))
    url = "http://%s:%d/metrics" % (host, port)

    res = ctx.run(["curl", "-sf", "--max-time", "10", url], mutates=False)

    if params.get("_discover"):
        if res.rc != 0:
            return {"changed": False, "msg": "cAdvisor not reachable",
                    "data": {"discovery": []}}
        has_net = False
        for line in res.stdout.splitlines():
            if line.startswith("container_network_receive_bytes_total{"):
                has_net = True
                break
        if not has_net:
            return {"changed": False, "msg": "no cAdvisor network metrics found",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [
                {
                    "item": "Summary",
                    "params": {},
                    "metrics": ["in", "out", "inerr", "outerr", "indisc", "outdisc"],
                },
            ]},
        }

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "cAdvisor not reachable at %s:%d (rc=%d)" % (host, port, res.rc),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    totals = _parse_prom(res.stdout)
    in_b = int(totals["in"])
    out_b = int(totals["out"])
    in_err = int(totals["inerr"])
    out_err = int(totals["outerr"])
    in_disc = int(totals["indisc"])
    out_disc = int(totals["outdisc"])

    item = params.get("item", "Summary")
    msg = "[%s] In: %d B, Out: %d B, Err in: %d, Err out: %d" % (
        item, in_b, out_b, in_err, out_err,
    )
    details = "Discards in: %d, Discards out: %d" % (in_disc, out_disc)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": {
                "in": in_b,
                "out": out_b,
                "inerr": in_err,
                "outerr": out_err,
                "indisc": in_disc,
                "outdisc": out_disc,
            },
            "details": details,
        },
    }