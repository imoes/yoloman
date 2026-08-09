def _safe_float(s):
    if not s:
        return 0.0
    sign = 1
    i = 0
    if s[0] == "-":
        sign = -1
        i = 1
    elif s[0] == "+":
        i = 1
    digits = ""
    seen_dot = False
    while i < len(s):
        c = s[i]
        if c >= "0" and c <= "9":
            digits = digits + c
        elif c == "." and not seen_dot:
            digits = digits + c
            seen_dot = True
        else:
            break
        i = i + 1
    if not digits:
        return 0.0
    return sign * _str_to_float(digits)

def _str_to_float(s):
    if "." in s:
        parts = s.split(".")
        int_part = parts[0]
        frac_part = parts[1]
        val = 0.0
        for c in int_part:
            val = val * 10.0
            d = ord(c) - ord("0")
            val = val + d
        frac_val = 0.0
        for c in reversed(frac_part):
            d = ord(c) - ord("0")
            frac_val = (frac_val + d) / 10.0
        return val + frac_val
    val = 0.0
    for c in s:
        val = val * 10.0
        d = ord(c) - ord("0")
        val = val + d
    return val

def _safe_int(s):
    if not s:
        return None
    sign = 1
    i = 0
    if s[0] == "-":
        sign = -1
        i = 1
    elif s[0] == "+":
        i = 1
    digits = ""
    while i < len(s):
        c = s[i]
        if c >= "0" and c <= "9":
            digits = digits + c
        else:
            break
        i = i + 1
    if not digits:
        return None
    val = 0
    for c in digits:
        val = val * 10
        d = ord(c) - ord("0")
        val = val + d
    return sign * val

def _safe_float_opt(s):
    if not s:
        return None
    return _safe_float(s)

def main(ctx, params):
    comm = params.get("community", "public")
    host = params.get("host", "localhost")
    if params.get("_discover"):
        sysdesc = ctx.run(["snmpget", "-v2c", "-c", comm, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sysdesc.rc != 0 or "fr5000" not in sysdesc.stdout:
            return {"changed": False, "msg": "no icom repeater", "data": {"discovery": [], "host_labels": {}}}
        base = ".1.3.6.1.4.1.2021.8.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", comm, "-Oqn", host, base + ".1"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no icom repeater data", "data": {"discovery": [], "host_labels": {}}}
        rows = {}
        for line in res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1]
            idx = oid[len(base) + ".0"]
            if idx not in rows:
                rows[idx] = {}
            rows[idx]["label"] = val
        parsed = _parse_section(ctx, rows, base, comm, host)
        items = []
        if "temp" in parsed:
            items.append({"item": "System", "params": {"levels": (50.0, 55.0), "levels_lower": (-20.0, -25.0)}, "metrics": ["temperature"]})
        if "ps_voltage" in parsed:
            items.append({"item": "", "params": {"levels_lower": (13.5, 13.2), "levels_upper": (14.1, 14.4)}, "metrics": ["voltage"]})
        if "tx_pll_lock_voltage" in parsed:
            items.append({"item": "TX", "params": {}, "metrics": ["voltage"]})
        if "rx_pll_lock_voltage" in parsed:
            items.append({"item": "RX", "params": {}, "metrics": ["voltage"]})
        items.append({"item": "", "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d services" % len(items), "data": {"discovery": items, "host_labels": {"cmk/os_family": "linux"}}}
    item = params.get("item", "")
    parsed = _fetch_full(ctx, params)
    if not parsed or "esnno" not in parsed:
        return {"changed": False, "msg": "no icom repeater data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item == "System":
        return _check_temp(parsed, params)
    if item == "":
        return _check_info(parsed)
    return _check_pll(parsed, item, params)

def _fetch_full(ctx, params):
    comm = params.get("community", "public")
    host = params.get("host", "localhost")
    base = ".1.3.6.1.4.1.2021.8.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", comm, "-Oqn", host, base + ".1"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {}
    rows = {}
    for line in res.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1]
        idx = oid[len(base) + ".0"]
        if idx not in rows:
            rows[idx] = {}
        rows[idx]["label"] = val
    return _parse_section(ctx, rows, base, comm, host)

def _parse_section(ctx, rows, base, comm, host):
    parsed = {}
    for idx, fields in rows.items():
        label = fields["label"]
        res2 = ctx.run(["snmpget", "-v2c", "-c", comm, "-Oqv", host, base + ".2." + idx], mutates=False)
        if res2.rc != 0:
            continue
        field_name = res2.stdout.strip() if res2.stdout else ""
        res3 = ctx.run(["snmpget", "-v2c", "-c", comm, "-Oqv", host, base + ".101." + idx], mutates=False)
        if res3.rc != 0:
            continue
        field_val = res3.stdout.strip() if res3.stdout else ""
        if field_name == "Temperature":
            parsed["temp"] = _safe_float(field_val[:-1])
            parsed["temp_devunit"] = field_val[-1].lower()
        elif field_name == "ESN number":
            parsed["esnno"] = field_val
        elif field_name == "Repeater operation":
            parsed["repop"] = field_val.lower()
        elif field_name == "Abnormal temperature detection":
            parsed["temp_devstatus"] = 0 if field_val == "Not detected" else 2
        elif field_name == "Power-supply voltage":
            parsed["ps_voltage"] = _safe_float(field_val[:-1])
        elif field_name == "Abnormal power-supply voltage detection":
            parsed["ps_volt_devstatus"] = 0 if field_val == "Not detected" else 2
        elif field_name == "TX PLL lock voltage":
            v = _safe_float_opt(field_val[:-1])
            if v != None:
                parsed["tx_pll_lock_voltage"] = v
        elif field_name == "RX PLL lock voltage":
            v = _safe_float_opt(field_val[:-1])
            if v != None:
                parsed["rx_pll_lock_voltage"] = v
        elif field_name == "Repeater frequency":
            freq = {}
            parts = field_val.split(",")
            for b in parts:
                b = b.strip()
                if ":" in b:
                    k = b.split(":")[0].lower()
                    num = _safe_int(b.split(":")[1])
                    if num != None:
                        freq[k] = num
            if freq:
                parsed["repeater_frequency"] = freq
    return parsed

def _check_temp(parsed, params):
    reading = parsed.get("temp", 0.0)
    levels = params.get("levels", (50.0, 55.0))
    levels_lower = params.get("levels_lower", (-20.0, -25.0))
    warn = levels[0]
    crit = levels[1]
    warn_l = levels_lower[0]
    crit_l = levels_lower[1]
    dev_status = parsed.get("temp_devstatus", 0)
    status = 0
    if dev_status != 0:
        status = 2
    if reading >= crit or reading <= crit_l:
        status = 2
    elif reading >= warn or reading <= warn_l:
        status = 1
    unit = parsed.get("temp_devunit", "c")
    state_names = ["OK", "WARN", "CRIT", "UNKNOWN"]
    msg = "%f %s" % (reading, unit)
    details = "Temperature %f %s (dev_status=%d, warn=%f/%f, crit=%f/%f)" % (reading, unit, dev_status, warn, warn_l, crit, crit_l)
    return {"changed": False, "msg": msg, "data": {"state": state_names[status], "metrics": {"temperature": reading}, "details": details}}

def _check_info(parsed):
    esn = parsed.get("esnno", "unknown")
    repop = parsed.get("repop", "")
    if repop == "off":
        status = 2
    elif repop == "on":
        status = 0
    else:
        status = 3
    state_names = ["OK", "WARN", "CRIT", "UNKNOWN"]
    msg = "ESN Number: %s" % esn
    details = "Repeater operation status: %s" % repop
    return {"changed": False, "msg": msg, "data": {"state": state_names[status], "metrics": {}, "details": details}}

def _check_pll(parsed, item, params):
    key = item.lower()
    voltage = parsed.get(key + "_pll_lock_voltage", 0.0)
    freq_map = parsed.get("repeater_frequency", {})
    freq_val = freq_map.get(key, 0) if freq_map else 0
    paramlist = params.get(key, None)
    if not paramlist:
        details = "voltage=%f" % voltage
        return {"changed": False, "msg": "Please specify parameters for PLL voltage", "data": {"state": "WARN", "metrics": {"voltage": voltage}, "details": details}}
    warn_lower = 0.0
    crit_lower = 0.0
    warn = 0.0
    crit = 0.0
    for entry in paramlist:
        if len(entry) >= 5 and entry[0] >= freq_val:
            warn_lower = entry[1]
            crit_lower = entry[2]
            warn = entry[3]
            crit = entry[4]
            break
    status = 0
    if voltage < crit_lower or voltage >= crit:
        status = 2
    elif voltage < warn_lower or voltage >= warn:
        status = 1
    state_names = ["OK", "WARN", "CRIT", "UNKNOWN"]
    msg = "%f V" % voltage
    details = "Voltage %f V (freq=%d, warn=%f/%f, crit=%f/%f)" % (voltage, freq_val, warn_lower, crit_lower, warn, crit)
    return {"changed": False, "msg": msg, "data": {"state": state_names[status], "metrics": {"voltage": voltage}, "details": details}}