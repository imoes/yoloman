def _status_text():
    return {
        1: "unknown",
        2: "normal",
        3: "observation",
        4: "warning - A3",
        5: "minor - MA",
        6: "major - CA",
        7: "unmanaged",
        8: "restricted",
        9: "testing",
        10: "disabled",
    }

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the Emerson device presence via sysDescr OID
        sysdescr_oid = ".1.3.6.1.4.1.6302.2.1.1.1.0"
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, sysdescr_oid],
            mutates=False,
        )
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no emerson device found",
                    "data": {"discovery": []}}
        # Confirm it is Emerson Network Power
        text = res.stdout.strip()
        if not text.startswith("Emerson Network Power"):
            return {"changed": False, "msg": "not an emerson device",
                    "data": {"discovery": []}}
        # Fetch the system status OID
        stat_oid = ".1.3.6.1.4.1.6302.2.1.2.1.0"
        sres = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, stat_oid],
            mutates=False,
        )
        if sres.rc != 0:
            return {"changed": False, "msg": "no emerson status data",
                    "data": {"discovery": []}}
        status_val = sres.stdout.strip()
        if not status_val.isdigit():
            return {"changed": False, "msg": "invalid emerson status",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["status"]}]}}
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    stat_oid = ".1.3.6.1.4.1.6302.2.1.2.1.0"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, stat_oid],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False,
                "msg": "no emerson status data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    if not raw.isdigit():
        return {"changed": False,
                "msg": "invalid emerson status value: %s" % raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = int(raw)
    texts = _status_text()
    stext = texts.get(status, "unknown")
    infotext = "Status: %s" % stext
    if status in [5, 6, 10]:
        state = "CRIT"
    elif status in [1, 3, 4, 7, 8, 9]:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False,
            "msg": infotext,
            "data": {"state": state, "metrics": {"status": status}, "details": infotext}}