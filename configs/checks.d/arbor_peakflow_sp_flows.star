def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real product: Arbor Peakflow SP enterprise OID .1.3.6.1.4.1.9694.1.4
    sys_id = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.9694.1.2.1.4.1"], mutates=False)
    if sys_id.rc != 0 or sys_id.stdout == "":
        return {"changed": False, "msg": "Arbor Peakflow SP not detected (snmpget failed)", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        # Verify the base OID exists before offering the single service
        probe = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.9694.1.4.2.1.12.0"], mutates=False)
        if probe.rc != 0 or probe.stdout == "":
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {"levels": (90, 95)}, "metrics": ["flows"]}], "host_labels": {"cmk/peakflow_sp": "true"}}}

    item = params.get("item", "")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.9694.1.4.2.1.12.0"], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "no flow count value retrieved", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    if not raw.isdigit():
        return {"changed": False, "msg": "invalid flow count value: %s" % raw, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    flows = int(raw)
    levels = params.get("levels", (90, 95))
    warn = levels[0] if len(levels) >= 1 else 90
    crit = levels[1] if len(levels) >= 2 else 95
    state = "CRIT" if flows >= crit else ("WARN" if flows >= warn else "OK")
    return {"changed": False, "msg": "Flows: %d" % flows, "data": {"state": state, "metrics": {"flows": flows}, "details": ""}}