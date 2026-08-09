def main(ctx, params):
    if params.get("_discover"):
        detect = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-Onqv", "-OV", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0",
        ], mutates=False)
        if detect.rc != 0:
            return {"changed": False, "msg": "no oracle_diva_csm device detected", "data": {"discovery": []}}
        if detect.stdout.strip() != ".1.3.6.1.4.1.311.1.1.3.1.2":
            return {"changed": False, "msg": "no oracle_diva_csm device detected", "data": {"discovery": []}}

        tapes_count = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.110901.1.4.3.0",
        ], mutates=False)
        if tapes_count.rc != 0:
            return {"changed": False, "msg": "no oracle_diva_csm device detected", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {"levels_lower": (5, 1)}, "metrics": ["tapes_free"]},
                ],
            },
        }

    tapes_count = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.110901.1.4.3.0",
    ], mutates=False)
    if tapes_count.rc != 0:
        return {
            "changed": False,
            "msg": "no oracle_diva_csm device reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw = tapes_count.stdout.strip()
    digits = raw.lstrip("-")
    if not digits.isdigit():
        return {
            "changed": False,
            "msg": "blank tape count unparseable: %s" % raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    blank_tapes = int(raw)

    levels_lower = params.get("levels_lower", (5, 1))
    state = "OK"
    warn = None
    crit = None
    if levels_lower != None and len(levels_lower) == 2:
        warn = levels_lower[0]
        crit = levels_lower[1]
        if warn != None and crit != None:
            if blank_tapes <= crit:
                state = "CRIT"
            elif blank_tapes <= warn:
                state = "WARN"

    msg = "Blank tapes: %d" % blank_tapes
    if warn != None and crit != None:
        msg = msg + " (warn <= %d, crit <= %d)" % (warn, crit)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {"tapes_free": blank_tapes}, "details": ""},
    }