def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1"], mutates=False)
        if not res.stdout:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        lines = res.stdout.splitlines()
        section = {}
        for line in lines:
            parts = line.strip().split()
            if len(parts) < 5:
                continue
            key = parts[4]
            if not key:
                continue
            value = int(parts[0]) if parts[0].lstrip("-").isdigit() else None
            # Build hierarchy path
            path = key.split(".")
            target = section
            for segment in path[:-1]:
                if segment not in target:
                    target[segment] = {}
                target = target[segment]
            # Extract description from remaining parts
            if len(parts) > 5:
                if parts[3].lower() in key:
                    descr = " ".join(parts[5:])
                else:
                    descr = " ".join(parts[4:])
            else:
                descr = ""
            # Normalize perf_var_name
            perf_var_name = "varnish_%s_rate" % path[-1]
            if perf_var_name.startswith("varnish_n_wrk"):
                perf_var_name = perf_var_name.replace("n_wrk", "worker")
            elif perf_var_name.startswith("varnish_n_"):
                perf_var_name = perf_var_name.replace("n_", "objects_")
            target[path[-1]] = {
                "value": value,
                "descr": descr.replace("/", " "),
                "perf_var_name": perf_var_name,
                "params_var_name": path[-1].split("_", 1)[-1],
            }
        if "n_wrk_failed" in section and "n_wrk_queued" in section:
            return {
                "changed": False,
                "msg": "discovered 1 items",
                "data": {"discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [
                            "n_wrk_lqueue_rate",
                            "n_wrk_create_rate",
                            "n_wrk_drop_rate",
                            "n_wrk_rate",
                            "n_wrk_failed_rate",
                            "n_wrk_queued_rate",
                            "n_wrk_max_rate"
                        ]
                    }
                ]}
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []}
        }

    # Check mode (single service)
    res = ctx.run(["varnishstat", "-1"], mutates=False)
    if not res.stdout:
        return {
            "changed": False,
            "msg": "Varnish worker data not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    lines = res.stdout.splitlines()
    section = {}
    for line in lines:
        parts = line.strip().split()
        if len(parts) < 5:
            continue
        key = parts[4]
        if not key:
            continue
        value = int(parts[0]) if parts[0].lstrip("-").isdigit() else None
        path = key.split(".")
        target = section
        for segment in path[:-1]:
            if segment not in target:
                target[segment] = {}
            target = target[segment]
        if len(parts) > 5:
            if parts[3].lower() in key:
                descr = " ".join(parts[5:])
            else:
                descr = " ".join(parts[4:])
        else:
            descr = ""
        perf_var_name = "varnish_%s_rate" % path[-1]
        if perf_var_name.startswith("varnish_n_wrk"):
            perf_var_name = perf_var_name.replace("n_wrk", "worker")
        elif perf_var_name.startswith("varnish_n_"):
            perf_var_name = perf_var_name.replace("n_", "objects_")
        target[path[-1]] = {
            "value": value,
            "descr": descr.replace("/", " "),
            "perf_var_name": perf_var_name,
            "params_var_name": path[-1].split("_", 1)[-1],
        }

    # Required keys for worker section
    required_keys = [
        "n_wrk_lqueue",
        "n_wrk_create",
        "n_wrk_drop",
        "n_wrk",
        "n_wrk_failed",
        "n_wrk_queued",
        "n_wrk_max"
    ]
    for key in required_keys:
        if key not in section:
            return {
                "changed": False,
                "msg": "Varnish worker data not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }

    # Compute metrics from current values (single time sample)
    metrics = {}
    summary_parts = []

    # Map raw keys to rate metric names for output
    key_to_rate = {
        "n_wrk_lqueue": "n_wrk_lqueue_rate",
        "n_wrk_create": "n_wrk_create_rate",
        "n_wrk_drop": "n_wrk_drop_rate",
        "n_wrk": "n_wrk_rate",
        "n_wrk_failed": "n_wrk_failed_rate",
        "n_wrk_queued": "n_wrk_queued_rate",
        "n_wrk_max": "n_wrk_max_rate"
    }

    for key in required_keys:
        if section[key].get("value") != None:
            value = section[key]["value"]
            metrics[key_to_rate[key]] = value

    # Build message from key metrics
    if section.get("n_wrk") and section["n_wrk"].get("value") != None:
        summary_parts.append("Active workers: %d" % section["n_wrk"]["value"])
    if section.get("n_wrk_failed") and section["n_wrk_failed"].get("value") != None:
        summary_parts.append("Failed: %d" % section["n_wrk_failed"]["value"])
    if section.get("n_wrk_drop") and section["n_wrk_drop"].get("value") != None:
        summary_parts.append("Dropped: %d" % section["n_wrk_drop"]["value"])
    if section.get("n_wrk_queued") and section["n_wrk_queued"].get("value") != None:
        summary_parts.append("Queued: %d" % section["n_wrk_queued"]["value"])

    msg = "Varnish Worker: " + ", ".join(summary_parts) if summary_parts else "Varnish Worker: data present"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": ""
        }
    }
