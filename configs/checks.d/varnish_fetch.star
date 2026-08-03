def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "varnishstat not available", "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "no varnishstat output", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        if not data:
            return {"changed": False, "msg": "empty varnishstat json", "data": {"discovery": []}}
        flat = {}
        for key in data:
            val = data[key]
            if isinstance(val, dict) and "value" in val:
                flat[key] = val
        required = ["fetch_1xx", "fetch_204", "fetch_304", "fetch_bad", "fetch_eof", "fetch_failed", "fetch_zero"]
        missing = False
        for k in required:
            if k not in flat:
                missing = True
                break
        if missing:
            return {"changed": False, "msg": "no varnish fetch data", "data": {"discovery": []}}
        metric_names = [
            "varnish_fetch_oldhttp_rate", "varnish_fetch_head_rate", "varnish_fetch_eof_rate",
            "varnish_fetch_zero_rate", "varnish_fetch_304_rate", "varnish_fetch_length_rate",
            "varnish_fetch_failed_rate", "varnish_fetch_bad_rate", "varnish_fetch_close_rate",
            "varnish_fetch_1xx_rate", "varnish_fetch_chunked_rate", "varnish_fetch_204_rate",
        ]
        return {
            "changed": False,
            "msg": "discovered varnish fetch",
            "data": {
                "discovery": [
                    {"item": "", "params": {"warn": 0.0, "crit": 0.0}, "metrics": metric_names}
                ]
            },
        }

    item = params.get("item", "")
    res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "varnishstat not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "no varnishstat output", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if not data:
        return {"changed": False, "msg": "empty varnishstat json", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    flat = {}
    for key in data:
        val = data[key]
        if isinstance(val, dict) and "value" in val:
            flat[key] = val

    metric_keys = [
        "fetch_oldhttp", "fetch_head", "fetch_eof", "fetch_zero", "fetch_304",
        "fetch_length", "fetch_failed", "fetch_bad", "fetch_close", "fetch_1xx",
        "fetch_chunked", "fetch_204",
    ]
    metrics = {}
    summary_parts = []
    perf_map = {
        "fetch_oldhttp": "varnish_fetch_oldhttp_rate",
        "fetch_head": "varnish_fetch_head_rate",
        "fetch_eof": "varnish_fetch_eof_rate",
        "fetch_zero": "varnish_fetch_zero_rate",
        "fetch_304": "varnish_fetch_304_rate",
        "fetch_length": "varnish_fetch_length_rate",
        "fetch_failed": "varnish_fetch_failed_rate",
        "fetch_bad": "varnish_fetch_bad_rate",
        "fetch_close": "varnish_fetch_close_rate",
        "fetch_1xx": "varnish_fetch_1xx_rate",
        "fetch_chunked": "varnish_fetch_chunked_rate",
        "fetch_204": "varnish_fetch_204_rate",
    }
    param_map = {
        "fetch_oldhttp": "oldhttp", "fetch_head": "head", "fetch_eof": "eof",
        "fetch_zero": "zero", "fetch_304": "304", "fetch_length": "length",
        "fetch_failed": "failed", "fetch_bad": "bad", "fetch_close": "close",
        "fetch_1xx": "1xx", "fetch_chunked": "chunked", "fetch_204": "204",
    }
    any_data = False
    for key in metric_keys:
        val = flat.get(key)
        if not isinstance(val, dict) or val.get("value") == None:
            continue
        any_data = True
        cur_val = val.get("value")
        cur_val = int(cur_val)
        pkey = perf_map[key]
        metrics[pkey] = 0.0
        summary_parts.append(pkey + ": init")
    if not any_data:
        return {"changed": False, "msg": "no varnish fetch data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    overall = "OK"
    for part in summary_parts:
        if "CRIT" in part:
            overall = "CRIT"
            break
        elif "WARN" in part and overall != "CRIT":
            overall = "WARN"
    if overall == "OK":
        msg = "Varnish Fetch: OK"
    else:
        msg = "Varnish Fetch: " + overall + ", " + ", ".join(summary_parts)
    return {"changed": False, "msg": msg, "data": {"state": overall, "metrics": metrics, "details": ""}}