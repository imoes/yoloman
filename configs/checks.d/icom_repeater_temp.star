def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.2021.8.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                   base_oid + ".2", base_oid + ".101"], mutates=False)
    lines = res.stdout.splitlines()

    temp = None
    devunit = None

    for line in lines:
        if ".2." in line and "Temperature" in line:
            if " = " in line:
                val_part = line.split(" = ", 1)[1].strip()
                if val_part.startswith("STRING: "):
                    desc_val = val_part[8:].strip('"')
                    continue
        if ".101." in line:
            if " = " in line:
                val_part = line.split(" = ", 1)[1].strip()
                if val_part.startswith("INTEGER: "):
                    raw = val_part[9:].strip()
                    temp = float(raw) if raw.replace(".", "", 1).replace("-", "", 1).isdigit() else None
                elif val_part.startswith("STRING: "):
                    raw = val_part[8:].strip('"')
                    if len(raw) > 0 and (raw[-1] == "C" or raw[-1] == "F"):
                        devunit = raw[-1].lower()
                        num_part = raw[:-1]
                        temp = float(num_part) if num_part.replace(".", "", 1).replace("-", "", 1).isdigit() else None
                    else:
                        temp = float(raw) if raw.replace(".", "", 1).replace("-", "", 1).isdigit() else None
                elif val_part.startswith(" Gauge32: "):
                    raw = val_part[10:].strip()
                    temp = float(raw) if raw.replace(".", "", 1).replace("-", "", 1).isdigit() else None
                else:
                    raw = val_part.strip()
                    temp = float(raw) if raw.replace(".", "", 1).replace("-", "", 1).isdigit() else None

    if temp == None:
        return {"changed": False,
                "msg": "no temperature data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "System",
                     "params": {"levels": (50.0, 55.0), "levels_lower": (-20.0, -25.0)},
                     "metrics": ["temp"]},
                ]}}

    item = params.get("item", "")
    if item != "System":
        return {"changed": False,
                "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", (50.0, 55.0))
    levels_lower = params.get("levels_lower", (-20.0, -25.0))

    warn_upper, crit_upper = levels[0], levels[1]
    warn_lower, crit_lower = levels_lower[0], levels_lower[1]

    if crit_upper != None and temp >= crit_upper:
        state = "CRIT"
    elif warn_upper != None and temp >= warn_upper:
        state = "WARN"
    else:
        if crit_lower != None and temp <= crit_lower:
            state = "CRIT"
        elif warn_lower != None and temp <= warn_lower:
            state = "WARN"
        else:
            state = "OK"

    unit = devunit.upper() if devunit else "C"
    msg = "Temperature: %f %s" % (temp, unit)
    if state != "OK":
        msg += " (warn/crit at %f/%f and %f/%f)" % (warn_upper, crit_upper, warn_lower, crit_lower)

    return {"changed": False,
            "msg": msg,
            "data": {"state": state,
                     "metrics": {"temp": temp},
                     "details": ""}}