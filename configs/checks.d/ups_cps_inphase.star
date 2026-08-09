# UPS Input Phase - Checkmk check translation to Starlark
# SNMP check for UPS input phase voltage/frequency monitoring

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: check if this is a UPSCPS device via sysObjectID
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "no ups cps input phase found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sys_obj_value = res.stdout.strip()
    # DETECT_UPS_CPS: startswith(".1.3.6.1.2.1.1.2.0", ".1.3.6.1.4.1.3808.1.1.1")
    if not sys_obj_value.startswith(".1.3.6.1.4.1.3808.1.1.1"):
        return {
            "changed": False,
            "msg": "not a UPS CPS device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if params.get("_discover"):
        voltage_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.3808.1.1.1.3.2.1.1"],
            mutates=False,
        )
        freq_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.3808.1.1.1.3.2.1.4"],
            mutates=False,
        )
        if voltage_res.rc != 0 and freq_res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        discovery = [
            {
                "item": "input_phase_1",
                "params": params.get("levels", {}),
                "metrics": ["input_voltage", "input_frequency"],
            }
        ]
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "input_phase_1")

    voltage_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.3808.1.1.1.3.2.1.1"],
        mutates=False,
    )
    freq_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.3808.1.1.1.3.2.1.4"],
        mutates=False,
    )

    metrics = {}
    details_parts = []
    state = "OK"

    levels = params.get("levels", {})

    # Parse voltage (divided by 10)
    if voltage_res.rc == 0 and voltage_res.stdout:
        v_str = voltage_res.stdout.strip()
        if v_str.lstrip("-").isdigit():
            voltage = float(int(v_str)) / 10
            metrics["input_voltage"] = voltage
            details_parts.append("Voltage: %f V" % voltage)
            v_levels = levels.get("voltage", {})
            if type(v_levels) == "dict":
                v_warn_up = v_levels.get("warn_upper")
                v_crit_up = v_levels.get("crit_upper")
                v_warn_lo = v_levels.get("warn_lower")
                v_crit_lo = v_levels.get("crit_lower")
                if v_crit_up != None and voltage >= v_crit_up:
                    state = "CRIT"
                elif v_warn_up != None and voltage >= v_warn_up:
                    state = "WARN"
                elif v_crit_lo != None and voltage <= v_crit_lo:
                    state = "CRIT"
                elif v_warn_lo != None and voltage <= v_warn_lo:
                    state = "WARN"
        else:
            state = "UNKNOWN"
            details_parts.append("voltage data invalid")
    else:
        state = "UNKNOWN"
        details_parts.append("voltage data unavailable")

    # Parse frequency (divided by 10)
    if freq_res.rc == 0 and freq_res.stdout:
        f_str = freq_res.stdout.strip()
        if f_str.lstrip("-").isdigit():
            frequency = float(int(f_str)) / 10
            metrics["input_frequency"] = frequency
            details_parts.append("Frequency: %f Hz" % frequency)
            f_levels = levels.get("frequency", {})
            if type(f_levels) == "dict":
                f_warn_up = f_levels.get("warn_upper")
                f_crit_up = f_levels.get("crit_upper")
                f_warn_lo = f_levels.get("warn_lower")
                f_crit_lo = f_levels.get("crit_lower")
                if f_crit_up != None and frequency >= f_crit_up:
                    state = "CRIT"
                elif f_warn_up != None and frequency >= f_warn_up:
                    state = "WARN"
                elif f_crit_lo != None and frequency <= f_crit_lo:
                    state = "CRIT"
                elif f_warn_lo != None and frequency <= f_warn_lo:
                    state = "WARN"
        else:
            if state != "OK":
                state = "UNKNOWN"
            details_parts.append("frequency data invalid")
    else:
        if state != "OK":
            state = "UNKNOWN"
        details_parts.append("frequency data unavailable")

    msg = ", ".join(details_parts) if details_parts else "no data"

    if state == "OK" and len(metrics) == 0:
        state = "UNKNOWN"
        msg = "no ups cps input phase data available"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": msg,
        },
    }