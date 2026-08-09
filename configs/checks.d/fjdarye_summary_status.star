FJDARYE_SUM_STATUS = {
    "1": ("CRIT", "Status: unknown"),
    "2": ("CRIT", "Status: unused"),
    "3": ("OK", "Status: ok"),
    "4": ("WARN", "Status: warning"),
    "5": ("CRIT", "Status: failed"),
}

def main(ctx, params):
    if params.get("_discover"):
        sysOid = ""
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if res.rc == 0 and res.stdout.strip() != "":
            sysOid = res.stdout.strip()
        if sysOid not in FJDARYE_SUM_STATUS:
            for device_oid in FJDARYE_SUM_STATUS:
                if sysOid == device_oid or sysOid.startswith(device_oid + "."):
                    pass
        valid = False
        for device_oid in [
            ".1.3.6.1.4.1.211.1.21.1.60",
            ".1.3.6.1.4.1.211.1.21.1.100",
            ".1.3.6.1.4.1.211.1.21.1.101",
            ".1.3.6.1.4.1.211.1.21.1.150",
            ".1.3.6.1.4.1.211.1.21.1.153",
        ]:
            if sysOid == device_oid:
                valid = True
                break
        if not valid:
            return {"changed": False, "msg": "no supported Fujitsu device found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {},
                                        "metrics": []}]}}
    item = params.get("item", "")
    sysOid = ""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "SNMP sysObjectID could not be read",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysOid = res.stdout.strip()
    status_oid = ""
    for device_oid in [
        ".1.3.6.1.4.1.211.1.21.1.60",
        ".1.3.6.1.4.1.211.1.21.1.100",
        ".1.3.6.1.4.1.211.1.21.1.101",
        ".1.3.6.1.4.1.211.1.21.1.150",
        ".1.3.6.1.4.1.211.1.21.1.153",
    ]:
        if sysOid == device_oid:
            status_oid = device_oid + ".6.0"
            break
    if status_oid == "":
        return {"changed": False, "msg": "SNMP agent is not a supported Fujitsu device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sres = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), status_oid],
        mutates=False,
    )
    if sres.rc != 0 or sres.stdout.strip() == "":
        return {"changed": False, "msg": "FJDARY-E summary status OID not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = sres.stdout.strip()
    entry = FJDARYE_SUM_STATUS.get(status)
    if entry == None:
        return {"changed": False,
                "msg": "Status: unknown (value %s)" % status,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state, summary = entry
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}