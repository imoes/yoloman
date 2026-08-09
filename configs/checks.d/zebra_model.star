def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")

        sys_descr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sys_descr.rc != 0 or "zebra" not in sys_descr.stdout.lower():
            return {"changed": False, "msg": "Zebra device not detected", "data": {"discovery": []}}

        tree1 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.10642.1.1.0"], mutates=False)
        tree2 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.10642.200.19.5.0"], mutates=False)
        tree3 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.10642.1.2.0"], mutates=False)
        tree4 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.10642.1.9.0"], mutates=False)

        if tree1.rc != 0 or tree2.rc != 0 or tree3.rc != 0 or tree4.rc != 0:
            return {"changed": False, "msg": "Zebra device not reachable", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered Zebra printer model",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    sys_descr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if sys_descr.rc != 0 or "zebra" not in sys_descr.stdout.lower():
        return {"changed": False, "msg": "Zebra printer not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    model_raw = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.10642.1.1.0"], mutates=False)
    serial_maybe_raw = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.10642.200.19.5.0"], mutates=False)
    serial_raw = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.10642.1.2.0"], mutates=False)
    release_raw = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.10642.1.9.0"], mutates=False)

    if model_raw.rc != 0 or serial_maybe_raw.rc != 0 or serial_raw.rc != 0 or release_raw.rc != 0:
        return {"changed": False, "msg": "Failed to gather Zebra printer data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    model = model_raw.stdout.strip()
    serial = serial_raw.stdout.strip()
    serial_maybe = serial_maybe_raw.stdout.strip()
    release = release_raw.stdout.strip()

    if not serial:
        serial = serial_maybe
    if not model:
        model = ""

    parts = []
    if model:
        parts.append("Zebra model: %s" % model)
    if serial:
        parts.append("Serial number: %s" % serial)
    if release:
        parts.append("Firmware release: %s" % release)

    summary = "; ".join(parts) if parts else "Zebra printer data unavailable"

    return {"changed": False, "msg": summary, "data": {"state": "OK", "metrics": {}, "details": ""}}