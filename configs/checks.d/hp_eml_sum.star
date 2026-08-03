def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-OvQ", "-m", "NONE", params.get("host", "localhost"),
                       ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0 or res.stdout.strip() == "":
            return {"changed": False, "msg": "not an HP EML device (sysOID mismatch or unreachable)",
                    "data": {"discovery": []}}
        sys_oid = res.stdout.strip()
        if sys_oid != ".1.3.6.1.4.1.11.10.2.1.3.20":
            return {"changed": False, "msg": "not an HP EML device (sysOID does not match)",
                    "data": {"discovery": []}}
        walk = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                        "-OvQ", "-m", "NONE", "-Oq", params.get("host", "localhost"),
                        ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.3",
                        ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.7",
                        ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.9",
                        ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.10",
                        ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.11"], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "HP EML device detected but summary OIDs unreachable",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-OvQ", "-m", "NONE", params.get("host", "localhost"),
                   ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "not an HP EML device (sysOID unreachable)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_oid = res.stdout.strip()
    if sys_oid != ".1.3.6.1.4.1.11.10.2.1.3.20":
        return {"changed": False, "msg": "not an HP EML device (sysOID does not match)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    walk = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-OvQ", "-m", "NONE", "-Oq", params.get("host", "localhost"),
                    ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.3",
                    ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.7",
                    ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.9",
                    ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.10",
                    ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.11"], mutates=False)
    if walk.rc != 0:
        return {"changed": False, "msg": "summary OIDs unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = walk.stdout.splitlines()
    if len(lines) < 5:
        return {"changed": False, "msg": "summary status information missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    values = [line.split(None, 1)[1].strip() if " " in line else line.strip() for line in lines[:5]]
    op_status = values[0].strip('"')
    manufacturer = values[1].strip('"')
    model = values[2].strip('"')
    serial = values[3].strip('"')
    version = values[4].strip('"')
    status_map = {
        "1": ("UNKNOWN", "unknown"),
        "2": ("OK", "unused"),
        "3": ("OK", "ok"),
        "4": ("WARN", "warning"),
        "5": ("CRIT", "critical"),
        "6": ("CRIT", "nonrecoverable"),
    }
    state_val, status_txt = status_map.get(op_status, ("UNKNOWN", "unhandled op_status (%s)" % op_status))
    summary = 'Summary State is "%s", Manufacturer: %s, Model: %s, Serial: %s, Version: %s' % (
        status_txt, manufacturer, model, serial, version)
    return {"changed": False, "msg": summary,
            "data": {"state": state_val, "metrics": {}, "details": ""}}