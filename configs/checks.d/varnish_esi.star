def _parse_varnishstats(output):
    sections = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        key = parts[0]
        val_str = parts[1]
        val = int(val_str) if val_str.lstrip("-").isdigit() else None
        # parts[2] is type (e.g. 'MAIN', 'MGT', or blank)
        # parts[3:] is description
        sections[key] = val
    return sections

VARNISH_STATS_KEYS = {
    "esi_errors": "varnish_esi_errors",
    "esi_warnings": "varnish_esi_warnings",
}

ESI_KEYS = ["esi_errors", "esi_warnings"]

def main(ctx, params):
    # Probe for varnishstat
    res = ctx.run(["varnishstat", "-1"], mutates=False)
    if res.rc == 127 or res.rc == 1:
        if params.get("_discover"):
            return {"changed": False, "msg": "varnishstat not installed", "data": {"discovery": []}}
        return {"changed": False, "msg": "Varnish not installed (varnishstat not found)", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats = _parse_varnishstats(res.stdout)

    if params.get("_discover"):
        if stats.get("esi_errors") != None:
            return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {"errors": (1.0, 2.0)}, "metrics": ["esi_errors", "esi_warnings"]}]}}
        return {"changed": False, "msg": "no ESI statistics found", "data": {"discovery": []}}

    # Check mode
    errors = stats.get("esi_errors")
    warnings = stats.get("esi_warnings")

    default_levels = (1.0, 2.0)
    warn, crit = params.get("errors", default_levels)

    metrics = {}
    state = "OK"
    details = []

    if errors != None:
        metrics["esi_errors"] = float(errors)
        if errors >= crit:
            state = "CRIT"
        elif errors >= warn:
            state = "WARN"
        details.append("ESI errors: %d" % errors)

    if warnings != None:
        metrics["esi_warnings"] = float(warnings)
        details.append("ESI warnings: %d" % warnings)

    if errors == None and warnings == None:
        return {"changed": False, "msg": "no ESI statistics available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": ", ".join(details), "data": {"state": state, "metrics": metrics, "details": "\n".join(details)}}