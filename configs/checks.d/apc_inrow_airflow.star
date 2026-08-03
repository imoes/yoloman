def main(ctx, params):
    # --- SNMP discovery / detection parameters ---
    host = params.get("host", params.get("snmp_host", "localhost"))
    community = params.get("community", "public")
    version = params.get("snmp_version", "2c")
    oid_sysDescr = ".1.3.6.1.2.1.1.2.0"

    # Detect whether this is an APC device (sysoid startswith .1.3.6.1.4.1.318)
    sysDescr_res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Ov", host, oid_sysDescr],
        mutates=False,
    )
    if sysDescr_res.rc != 0:
        return {"changed": False, "msg": "no SNMP response from " + host,
                "data": {"discovery": []}}
    sysDescr_val = sysDescr_res.stdout.strip()
    # -Ov keeps a leading TYPE: tag; strip everything up to and including first ": "
    if ": " in sysDescr_val:
        sysDescr_val = sysDescr_val.split(": ", 1)[1]
    if '"' in sysDescr_val:
        sysDescr_val = sysDescr_val.strip('"')
    # Strip OID prefix: snmpget prints ".1.3.6.1.2.1.1.2.0 = OID: .1.3.6.1.4.1.318..."
    if "=" in sysDescr_val:
        sysDescr_val = sysDescr_val.split()[-1]
    if not sysDescr_val.startswith(".1.3.6.1.4.1.318"):
        return {"changed": False, "msg": "host is not an APC device",
                "data": {"discovery": []}}

    # --- Discovery mode ---
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.318.1.1.13.3.2.2.2"
        col_oid = base_oid + ".5"
        res = ctx.run(
            ["snmpget", "-v" + version, "-c", community, "-Oqv", host, col_oid],
            mutates=False,
        )
        if res.rc != 0 or res.stdout.strip() == "":
            return {"changed": False, "msg": "no APC InRow airflow data",
                    "data": {"discovery": []}}
        discovery = [{
            "item": "",
            "params": {
                "level_low": params.get("level_low", [500.0, 200.0]),
                "level_high": params.get("level_high", [1000.0, 1100.0]),
            },
            "metrics": ["airflow"],
        }]
        return {"changed": False, "msg": "discovered 1 airflow sensor",
                "data": {"discovery": discovery}}

    # --- Check mode ---
    base_oid = ".1.3.6.1.4.1.318.1.1.13.3.2.2.2"
    col_oid = base_oid + ".5"
    res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, col_oid],
        mutates=False,
    )
    if res.rc != 0 or res.stdout.strip() == "":
        return {"changed": False, "msg": "no airflow value found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    # -Oqv gives bare value, but guard against any residual type tag / quotes
    if ": " in raw:
        raw = raw.split(": ", 1)[1]
    raw = raw.strip().strip('"')
    flow = None
    parts = raw.split()
    if len(parts) > 0 and parts[0] not in ("", " "):
        try_float = parts[0]
        # Manual float parse without try/except
        valid = True
        if try_float.startswith("-"):
            try_float = try_float[1:]
        if try_float.count(".") > 1:
            valid = False
        else:
            digits = try_float.replace(".", "")
            if digits == "" or not digits.isdigit():
                valid = False
        if valid and try_float != "":
            flow = float(try_float)

    if flow == None:
        return {"changed": False, "msg": "cannot parse airflow value: " + raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Thresholds (Checkmk defaults from check_default_parameters)
    level_low = params.get("level_low", [500.0, 200.0])
    level_high = params.get("level_high", [1000.0, 1100.0])
    warn_low = level_low[0] if len(level_low) >= 1 else 500.0
    crit_low = level_low[1] if len(level_low) >= 2 else 200.0
    warn_high = level_high[0] if len(level_high) >= 1 else 1000.0
    crit_high = level_high[1] if len(level_high) >= 2 else 1100.0

    state = "OK"
    message = ""

    # Low thresholds: warn if flow <= warn_low, crit if flow <= crit_low
    if crit_low != None and flow <= crit_low:
        state = "CRIT"
        message = "too low"
    elif warn_low != None and flow <= warn_low:
        state = "WARN"
        message = "too low"

    # High thresholds: warn if flow >= warn_high, crit if flow >= crit_high
    if crit_high != None and flow >= crit_high:
        state = "CRIT"
        message = "too high"
    elif warn_high != None and flow >= warn_high:
        state = "WARN"
        message = "too high"

    summary = "Current: %d l/s %s" % (int(flow + 0.5), message)
    return {"changed": False,
            "msg": summary,
            "data": {"state": state,
                     "metrics": {"airflow": flow},
                     "details": ""}}