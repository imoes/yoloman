def main(ctx, params):
    if params.get("_discover"):
        # Discovery: always yield one service if any Zebra SNMP data is present
        # We detect by trying each SNMP tree; if at least one returns data, we have a service
        res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.10642.1.1.0"], mutates=False)
        res2 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.683.1.9.0"], mutates=False)
        res3 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.683.6.2.3.2.1.15.1"], mutates=False)
        # If any output exists, we have a Zebra device
        has_data = (res1.stdout.strip() != "") or (res2.stdout.strip() != "") or (res3.stdout.strip() != "")
        if has_data:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
            }
        return {
            "changed": False,
            "msg": "no Zebra printer detected",
            "data": {"discovery": []}
        }

    # Check mode: fetch SNMP data and produce summary
    # Tree 1: .1.3.6.1.4.1.10642 (Zebra Technologies)
    #   .1.1.0 = model, .1.2.0 = release, .1.9.0 = serial (legacy)
    #   .200.19.5.0 = alternate serial
    # Tree 2: .1.3.6.1.4.1.683.1.9.0 = alternate release
    # Tree 3: .1.3.6.1.4.1.683.6.2.3.2.1.15.1 = alternate model (Zebra GK/GT series)
    model_res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.10642.1.1.0"], mutates=False)
    serial_res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.10642.1.9.0"], mutates=False)
    alt_serial_res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.10642.200.19.5.0"], mutates=False)
    release_res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.10642.1.2.0"], mutates=False)
    alt_release_res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.683.1.9.0"], mutates=False)
    alt_model_res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "127.0.0.1", ".1.3.6.1.4.1.683.6.2.3.2.1.15.1"], mutates=False)

    # Parse single-value SNMP GET results: expect "OID = STRING: value" or similar
    def get_value(res):
        if res.rc != 0:
            return None
        line = res.stdout.strip()
        if line == "":
            return None
        # Extract after last ": " or "=" or " = "
        idx = line.rfind(":")
        if idx == -1:
            idx = line.rfind("=")
        if idx == -1:
            return None
        val = line[idx + 1:].strip().strip('"').strip("'")
        return val if val != "" else None

    # Priority: primary model -> alternate model -> "unknown"
    model = get_value(model_res)
    if model == None:
        model = get_value(alt_model_res)

    # Priority: primary serial -> alt serial
    serial = get_value(serial_res)
    if serial == None:
        serial = get_value(alt_serial_res)

    # Priority: primary release -> alt release
    release = get_value(release_res)
    if release == None:
        release = get_value(alt_release_res)

    # Build result
    msg_parts = []
    state = "OK"

    if model == None:
        state = "UNKNOWN"
        msg_parts.append("No Zebra model detected")

    summary = "Zebra model: %s" % (model if model != None else "unknown")
    msg_parts.append(summary)

    if serial != None:
        msg_parts.append("Serial number: %s" % serial)

    if release != None:
        msg_parts.append("Firmware release: %s" % release)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
