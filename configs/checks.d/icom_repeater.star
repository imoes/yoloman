def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn_temp, crit_temp = params.get("levels", (50.0, 55.0))
    warn_temp_lower, crit_temp_lower = params.get("levels_lower", (-20.0, -25.0))
    ps_levels_upper = params.get("levels_upper", (14.1, 14.4))
    ps_levels_lower = params.get("levels_lower", (13.5, 13.2))
    pll_params = params.get("pll_levels", {})

    if params.get("_discover"):
        return _discover(ctx, community, host)

    item = params.get("item", "")
    if item == "":
        return _check_repeater_info(ctx, community, host)
    elif item == "System":
        return _check_temperature(ctx, community, host, warn_temp, crit_temp, warn_temp_lower, crit_temp_lower)
    elif item.upper() == "PS":
        return _check_ps_volt(ctx, community, host, ps_levels_upper, ps_levels_lower)
    elif item.upper() in ["RX", "TX"]:
        return _check_pll_volt(ctx, community, host, item.upper(), pll_params)
    else:
        fail("unknown item: " + item)


def _discover(ctx, community, host):
    section = _parse_icom_repeater_real(ctx, community, host)

    out = []
    if section:
        out.append({"item": "", "params": {}, "metrics": ["repeater_operation_status"]})
    if "temp" in section:
        out.append({"item": "System", "params": {"levels": (50.0, 55.0), "levels_lower": (-20.0, -25.0)},
                    "metrics": ["temp"]})
    if "ps_voltage" in section:
        out.append({"item": "", "params": {"levels_upper": (14.1, 14.4), "levels_lower": (13.5, 13.2)},
                    "metrics": ["voltage"]})
    if "rx_pll_lock_voltage" in section:
        out.append({"item": "RX", "params": {}, "metrics": ["voltage"]})
    if "tx_pll_lock_voltage" in section:
        out.append({"item": "TX", "params": {}, "metrics": ["voltage"]})

    return {"changed": False, "msg": "discovered %d services" % len(out), "data": {"discovery": out}}


def _parse_icom_repeater_real(ctx, community, host):
    parsed = {}

    names_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.2021.8.1.101.1"
    ], mutates=False)

    values_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.2021.8.1.101.2"
    ], mutates=False)

    if names_res.rc != 0 or values_res.rc != 0:
        return parsed

    names = _extract_snmp_values(names_res.stdout)
    values = _extract_snmp_values(values_res.stdout)

    for i in range(min(len(names), len(values))):
        name = names[i].strip()
        value = values[i].strip()
        if name.startswith('"') and name.endswith('"'):
            name = name[1:-1]
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]

        name_lower = name.lower()
        if "temperature" in name_lower:
            if len(value) > 1:
                temp_str = value[:-1]
                if temp_str.replace(".", "").replace("-", "").isdigit():
                    parsed["temp"] = float(temp_str)
                    parsed["temp_devunit"] = value[-1].lower()
        elif "esn number" in name_lower:
            parsed["esnno"] = value
        elif "repeater operation" in name_lower:
            parsed["repop"] = value.lower()
        elif "abnormal temperature detection" in name_lower:
            if value == "Not detected":
                parsed["temp_devstatus"] = 0
            else:
                parsed["temp_devstatus"] = 2
        elif "power-supply voltage" in name_lower:
            if len(value) > 1:
                volt_str = value[:-1]
                if volt_str.replace(".", "").replace("-", "").isdigit():
                    parsed["ps_voltage"] = float(volt_str)
        elif "abnormal power-supply voltage detection" in name_lower:
            if value == "Not detected":
                parsed["ps_volt_devstatus"] = 0
            else:
                parsed["ps_volt_devstatus"] = 2
        elif "tx pll lock voltage" in name_lower:
            if len(value) > 1:
                volt_str = value[:-1]
                if volt_str.replace(".", "").replace("-", "").isdigit():
                    parsed["tx_pll_lock_voltage"] = float(volt_str)
        elif "rx pll lock voltage" in name_lower:
            if len(value) > 1:
                volt_str = value[:-1]
                if volt_str.replace(".", "").replace("-", "").isdigit():
                    parsed["rx_pll_lock_voltage"] = float(volt_str)
        elif "repeater frequency" in name_lower:
            freqs = {}
            parts = value.split(",")
            for part in parts:
                kv = part.strip().split(":")
                if len(kv) == 2:
                    k = kv[0].lower()
                    if kv[1].isdigit():
                        freqs[k] = int(kv[1])
            parsed["repeater_frequency"] = freqs

    return parsed


def _extract_snmp_values(output):
    out = []
    for line in output.splitlines():
        eq = line.find("=")
        if eq == -1:
            continue
        val = line[eq+1:].strip()
        colon = val.find(":")
        if colon != -1:
            val = val[colon+1:].strip()
        val = val.strip('"')
        out.append(val)
    return out


def _check_repeater_info(ctx, community, host):
    section = _parse_icom_repeater_real(ctx, community, host)
    if not section:
        return {"changed": False, "msg": "no SNMP data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    esn = section.get("esnno", "N/A")
    repop = section.get("repop", "")
    state = "OK"
    summary = "ESN Number: %s; Operation: %s" % (esn, repop)
    if repop == "off":
        state = "CRIT"
        summary = "Repeater operation status: off"
    elif repop == "on":
        state = "OK"
        summary = "Repeater operation status: on"
    else:
        state = "UNKNOWN"
        summary = "Repeater operation status unknown"

    metrics = {}
    if repop == "on":
        metrics["repeater_operation_status"] = 0
    elif repop == "off":
        metrics["repeater_operation_status"] = 2
    else:
        metrics["repeater_operation_status"] = 3

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _check_temperature(ctx, community, host, warn, crit, warn_lower, crit_lower):
    section = _parse_icom_repeater_real(ctx, community, host)
    if "temp" not in section:
        return {"changed": False, "msg": "temperature data missing", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = section["temp"]
    dev_status = section.get("temp_devstatus", 0)

    state = "OK"
    summary = "%f C" % reading
    if dev_status == 2:
        state = "CRIT"
        summary = "Abnormal temperature detection: %f C" % reading
    else:
        if reading >= crit or reading <= crit_lower:
            state = "CRIT"
        elif reading >= warn or reading <= warn_lower:
            state = "WARN"

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"temp": reading}, "details": ""}}


def _check_ps_volt(ctx, community, host, levels_upper, levels_lower):
    section = _parse_icom_repeater_real(ctx, community, host)
    if "ps_voltage" not in section:
        return {"changed": False, "msg": "power supply voltage data missing", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    voltage = section["ps_voltage"]
    warn_u, crit_u = levels_upper
    warn_l, crit_l = levels_lower

    state = "OK"
    summary = "%f V" % voltage
    if voltage >= crit_u or voltage <= crit_l:
        state = "CRIT"
    elif voltage >= warn_u or voltage <= warn_l:
        state = "WARN"

    if state != "OK":
        summary += " (warn/crit below %f/%f V and at or above %f/%f V)" % (warn_l, crit_l, warn_u, crit_u)

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"voltage": voltage}, "details": ""}}


def _check_pll_volt(ctx, community, host, item, pll_params):
    section = _parse_icom_repeater_real(ctx, community, host)
    key = item.lower() + "_pll_lock_voltage"
    if key not in section:
        return {"changed": False, "msg": item + " PLL lock voltage data missing", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    voltage = section[key]
    freq = section.get("repeater_frequency", {}).get(item.lower(), 0)

    paramlist = pll_params.get(item.lower(), [])

    if not paramlist:
        return {"changed": False, "msg": "Please specify parameters for PLL voltage",
                "data": {"state": "WARN", "metrics": {"voltage": voltage}, "details": ""}}

    warn_lower, crit_lower, warn, crit = (0.0, 0.0, 0.0, 0.0)
    i = 0
    found = False
    while i < len(paramlist):
        if paramlist[i][0] >= freq:
            if i > 0:
                _, warn_lower, crit_lower, warn, crit = paramlist[i - 1]
            found = True
            break
        i += 1

    if not found and paramlist:
        _, warn_lower, crit_lower, warn, crit = paramlist[-1]

    summary = "%f V" % voltage
    levelstext = " (warn/crit below %f/%f V and at or above %f/%f V)" % (warn_lower, crit_lower, warn, crit)
    if voltage < crit_lower or voltage >= crit:
        state = "CRIT"
    elif voltage < warn_lower or voltage >= warn:
        state = "WARN"
    else:
        state = "OK"

    if state != "OK":
        summary += levelstext

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"voltage": voltage}, "details": ""}}