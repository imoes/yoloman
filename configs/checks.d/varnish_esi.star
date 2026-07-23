def main(ctx, params):
    # Discovery mode: detect if ESI data is available
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "Varnish not available or varnishstat failed",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout) if res.stdout else None
        if not isinstance(data, dict):
            return {"changed": False, "msg": "Invalid varnishstat JSON format",
                    "data": {"discovery": []}}
        # Check for ESI-related keys at top level (after MAIN prefix removal)
        section = data.get("MAIN", {})
        has_esi = isinstance(section, dict) and "esi_errors" in section
        if has_esi:
            return {"changed": False, "msg": "discovered 1 Varnish ESI service",
                    "data": {"discovery": [{"item": "", "params": {"errors": [1.0, 2.0]}, "metrics": ["esi_errors", "esi_warnings"]}]}}
        else:
            return {"changed": False, "msg": "no Varnish ESI data available",
                    "data": {"discovery": []}}

    # Check mode: process ESI metrics
    item = params.get("item", "")
    if item != "":
        return {"changed": False, "msg": "unexpected item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "varnishstat failed with code " + str(res.rc),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "varnishstat produced no output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout) if res.stdout else None
    if not isinstance(data, dict):
        return {"changed": False, "msg": "could not parse varnishstat JSON",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = data.get("MAIN", {})
    if not isinstance(section, dict):
        return {"changed": False, "msg": "invalid MAIN section format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    errors = section.get("esi_errors", {})
    warnings = section.get("esi_warnings", {})

    if not isinstance(errors, dict) or "value" not in errors:
        return {"changed": False, "msg": "esi_errors data missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not isinstance(warnings, dict) or "value" not in warnings:
        return {"changed": False, "msg": "esi_warnings data missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    err_val = errors["value"]
    warn_val = warnings["value"]

    # Use default thresholds from Checkmk source: {"errors": (1.0, 2.0)}
    err_warn, err_crit = 1.0, 2.0
    warn_levels = params.get("errors", (err_warn, err_crit))
    if isinstance(warn_levels, list) and len(warn_levels) == 2:
        err_warn = float(warn_levels[0])
        err_crit = float(warn_levels[1])
    elif isinstance(warn_levels, tuple) and len(warn_levels) == 2:
        err_warn = float(warn_levels[0])
        err_crit = float(warn_levels[1])

    state = "OK"
    if err_val >= err_crit:
        state = "CRIT"
    elif err_val >= err_warn:
        state = "WARN"

    msg_parts = []
    msg_parts.append("Errors: %d" % err_val)
    msg_parts.append("Warnings: %d" % warn_val)
    msg = "; ".join(msg_parts)

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"esi_errors": err_val, "esi_warnings": warn_val},
                     "details": ""}}