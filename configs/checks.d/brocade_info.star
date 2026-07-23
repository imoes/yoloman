def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.2.1.1.2.0"], mutates=False)
        oid = res.stdout.strip().split()[-1] if res.stdout.strip() else ""
        if (oid.startswith(".1.3.6.1.4.1.1588") or
            oid.startswith(".1.3.6.1.24.1.1588.2.1.1") or
            oid == ".1.3.6.1.4.1.1916.2.306"):
            res2 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.1588.2.1.1.1.1.6.0"], mutates=False)
            if res2.rc == 0 and res2.stdout.strip():
                return {"changed": False, "msg": "discovered 1 item",
                        "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    # Check mode
    # Gather required SNMP data
    res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.2.1.47.1.1.1.1.2.1"], mutates=False)
    res2 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.1588.2.1.1.1.1.6.0"], mutates=False)
    res3 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.1588.2.1.1.1.1.10.0"], mutates=False)
    res4 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.3.94.1.6.1.1.0"], mutates=False)

    model = "-"
    fw = "-"
    ssn = "-"
    wwn = "-"

    # Extract model (res1)
    out1 = res1.stdout.strip()
    if out1:
        tokens = out1.split()
        if len(tokens) >= 2 and tokens[-2].endswith("="):
            val = tokens[-1].strip('"')
            if val:
                model = val

    # Extract firmware (res2)
    out2 = res2.stdout.strip()
    if out2:
        tokens = out2.split()
        if len(tokens) >= 2 and tokens[-2].endswith("="):
            val = tokens[-1].strip('"')
            if val:
                fw = val

    # Extract SSN (res3)
    out3 = res3.stdout.strip()
    if out3:
        tokens = out3.split()
        if len(tokens) >= 2 and tokens[-2].endswith("="):
            val = tokens[-1].strip('"')
            if val:
                ssn = val

    # Extract WWN (res4)
    out4 = res4.stdout.strip()
    if out4:
        tokens = out4.split()
        if len(tokens) >= 2 and tokens[-2].endswith("="):
            val = tokens[-1]
            # Parse hex bytes
            if val and val != "\"\"":
                parts = val.split()
                if len(parts) >= 8:
                    wwn = ":".join(["%X" % int(p, 16) for p in parts[:8]])
                else:
                    wwn = val.strip('"')
            else:
                wwn = "-"

    # Build combined data
    data = "".join((model, ssn, fw, wwn))
    if data != "----":
        wwn_out = wwn
        if wwn_out == "":
            wwn_out = "-"
        elif wwn_out != "-":
            wwn_out = ":".join(wwn_out.split(" ")[:8])
        infotext = "Model: %s, SSN: %s, Firmware Version: %s, WWN: %s" % (model, ssn, fw, wwn_out)
        return {"changed": False, "msg": infotext,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    return {"changed": False, "msg": "no information found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
