def main(ctx, params):
    # === discovery mode ===
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # base OID: .1.3.6.1.4.1.11.2.14.11.1.2.8.1.1
        # fetch .2 (Sys-1) and .3 (current temp) for each entry
        base_oid = ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed: " + res.stderr,
                "data": {"discovery": []}
            }

        # parse lines like:
        # .1.3.6.1.4.1.11.2.14.11.1.2.8.1.1.2.0 = STRING: "Sys-1"
        # .1.3.6.1.4.1.11.2.14.11.1.2.8.1.1.3.0 = STRING: "21C"
        # We only need the first entry's sys name and current temp.
        sys_name = None
        raw_temp = None
        lines = res.stdout.splitlines()
        for line in lines:
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, val_part = parts
            if oid_part.endswith(".2.0"):
                # strip quotes if present
                sys_name = val_part.strip().strip('"')
            elif oid_part.endswith(".3.0"):
                raw_temp = val_part.strip().strip('"')

        if sys_name and raw_temp:
            return {
                "changed": False,
                "msg": "discovered 1 sensor",
                "data": {
                    "discovery": [{
                        "item": sys_name,
                        "params": {},
                        "metrics": ["temp"]
                    }]
                }
            }
        return {
            "changed": False,
            "msg": "no temperature sensor found",
            "data": {"discovery": []}
        }

    # === check mode ===
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1"

    # fetch only the specific OIDs we need for the item
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        base_oid + ".2.0",
        base_oid + ".3.0"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpget failed: " + res.stderr,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    sys_name = None
    raw_temp = None
    lines = res.stdout.splitlines()
    for line in lines:
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, val_part = parts
        if oid_part.endswith(".2.0"):
            sys_name = val_part.strip().strip('"')
        elif oid_part.endswith(".3.0"):
            raw_temp = val_part.strip().strip('"')

    # item mismatch -> UNKNOWN
    if sys_name != item:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # parse temperature: "21C" -> 21, 'C'
    if not raw_temp or len(raw_temp) < 2:
        return {
            "changed": False,
            "msg": "invalid temperature value",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    temp_str = raw_temp[:-1]
    dev_unit = raw_temp[-1].lower()

    if not temp_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid temperature value: " + raw_temp,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    temp = int(temp_str)

    # extract thresholds from params (checkmk defaults to None)
    warn = params.get("levels_upper", (None, None))
    warn = warn[0] if len(warn) >= 1 and warn[0] != None else None
    crit = params.get("levels_upper", (None, None))
    crit = crit[1] if len(crit) >= 2 and crit[1] != None else None

    # apply check_temperature logic manually (only upper levels)
    # check_temperature: warn and crit are upper thresholds (same unit)
    # state = CRIT if crit is set and temp >= crit
    #         WARN if warn is set and temp >= warn
    #         OK otherwise
    state = "OK"
    details = ""
    if crit != None and temp >= crit:
        state = "CRIT"
        details = "Temperature is above critical threshold ({}°C >= {}°C)".format(temp, crit)
    elif warn != None and temp >= warn:
        state = "WARN"
        details = "Temperature is above warning threshold ({}°C >= {}°C)".format(temp, warn)

    # metric name: hp_procurve_temp_<item>
    metric_name = "hp_procurve_temp_" + item
    perfdata = {"temp": temp}

    msg = "Temperature: {}°C".format(temp)
    if state == "CRIT":
        msg = "CRIT - " + msg
    elif state == "WARN":
        msg = "WARN - " + msg

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": perfdata,
            "details": details
        }
    }