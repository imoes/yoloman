def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sys_descr = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv",
             host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sys_descr.rc == 127 or sys_descr.rc != 0:
            return {"changed": False, "msg": "snmpget not available",
                    "data": {"discovery": []}}
        if not sys_descr.stdout or "zebra" not in sys_descr.stdout.lower():
            return {"changed": False, "msg": "no Zebra printer detected",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {},
                     "metrics": []}]}}
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, ".1.3.6.1.2.1.25.3.5.1.1.1"], mutates=False)
    if res.rc == 127 or res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no Zebra printer status available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    zebra_status = res.stdout.strip()
    if zebra_status == "3":
        return {"changed": False,
                "msg": "Printer is online and ready for the next print job",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    if zebra_status == "4":
        return {"changed": False, "msg": "Printer is printing",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    if zebra_status == "5":
        return {"changed": False, "msg": "Printer is warming up",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    if zebra_status == "1":
        return {"changed": False, "msg": "Printer is offline",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Unknown printer status",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}