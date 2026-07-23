def main(ctx, params):
    if params.get("_discover"):
        hostname = params.get("host", ctx.facts().get("hostname", "localhost"))
        community = params.get("community", "public")
        
        # Detect device type
        res_sys_object = ctx.run(["snmpget", "-v2c", "-c", community, "-On", hostname, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        res_sys_desc = ctx.run(["snmpget", "-v2c", "-c", community, "-On", hostname, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        
        sys_object_id = ""
        sys_desc = ""
        for line in res_sys_object.stdout.splitlines():
            if "=" in line:
                sys_object_id = line.split("=")[-1].strip()
                break
        for line in res_sys_desc.stdout.splitlines():
            if "=" in line:
                sys_desc = line.split("=")[-1].strip()
                break
        
        base_oid = ""
        if "1.3.6.1.4.1.1271.1.2.11" in sys_object_id and "5171" in sys_desc:
            base_oid = ".1.3.6.1.4.1.1271.2.1.9.1.1.1.1"
        elif "1.3.6.1.4.1.6141.1.96" in sys_object_id and "5142" in sys_desc:
            base_oid = ".1.3.6.1.4.1.6141.2.60.4.1.1.1.1"
        else:
            base_oid = ".1.3.6.1.4.1.6141.2.60.4.1.1.1.1"
        
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", hostname, base_oid], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith(base_oid):
                parts = stripped.split("=")
                if len(parts) < 2:
                    continue
                oid_full = parts[0].strip()
                port_str = oid_full.rsplit(".", 1)[-1]
                if port_str.isdigit():
                    out.append({"item": port_str, "params": {}, "metrics": ["input_signal_power_dbm", "output_signal_power_dbm"]})
        
        return {"changed": False, "msg": "discovered %d ports" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    hostname = params.get("host", ctx.facts().get("hostname", "localhost"))
    community = params.get("community", "public")
    
    res_sys_object = ctx.run(["snmpget", "-v2c", "-c", community, "-On", hostname, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    res_sys_desc = ctx.run(["snmpget", "-v2c", "-c", community, "-On", hostname, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    
    sys_object_id = ""
    sys_desc = ""
    for line in res_sys_object.stdout.splitlines():
        if "=" in line:
            sys_object_id = line.split("=")[-1].strip()
            break
    for line in res_sys_desc.stdout.splitlines():
        if "=" in line:
            sys_desc = line.split("=")[-1].strip()
            break
    
    base_oid = ""
    if "1.3.6.1.4.1.1271.1.2.11" in sys_object_id and "5171" in sys_desc:
        base_oid = ".1.3.6.1.4.1.1271.2.1.9.1.1.1.1"
    elif "1.3.6.1.4.1.6141.1.96" in sys_object_id and "5142" in sys_desc:
        base_oid = ".1.3.6.1.4.1.6141.2.60.4.1.1.1.1"
    else:
        base_oid = ".1.3.6.1.4.1.6141.2.60.4.1.1.1.1"
    
    base_item = base_oid + "." + item
    
    oids = {
        "rx_power": base_item + ".19",
        "rx_high": base_item + ".42",
        "rx_low": base_item + ".43",
        "tx_power": base_item + ".27",
        "tx_high": base_item + ".40",
        "tx_low": base_item + ".41"
    }
    
    oid_exists = True
    for oid_name, oid_full in oids.items():
        res_single = ctx.run(["snmpget", "-v2c", "-c", community, "-On", hostname, oid_full], mutates=False)
        if "No Such Instance" in res_single.stdout or "No Such Object" in res_single.stdout:
            oid_exists = False
            break
    
    if not oid_exists:
        return {"changed": False, "msg": "no such port: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", hostname, base_item], mutates=False)
    
    values = {}
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split("=")
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        last_oid = oid_full.rsplit(".", 1)[-1]
        if last_oid == "19":
            values["rx_power"] = value_part
        elif last_oid == "42":
            values["rx_high"] = value_part
        elif last_oid == "43":
            values["rx_low"] = value_part
        elif last_oid == "27":
            values["tx_power"] = value_part
        elif last_oid == "40":
            values["tx_high"] = value_part
        elif last_oid == "41":
            values["tx_low"] = value_part
    
    def micro_watt_to_dBm(m_w_str):
        if not m_w_str.isdigit():
            m_w = 0
        else:
            m_w = int(m_w_str)
        if m_w == 0:
            return -999.0
        mW = m_w / 1000.0
        if mW <= 0:
            return -999.0
        
        exp = 0
        temp = mW
        while temp < 0.1:
            temp *= 10
            exp -= 1
        while temp >= 10:
            temp /= 10
            exp += 1
        
        y = (temp - 1) / (temp + 1)
        y2 = y * y
        s = 0.0
        term = y
        for i in range(1, 10, 2):
            s += term / i
            term *= y2
        
        ln_temp = 2.0 * s
        log10_temp = ln_temp / 2.302585092994046
        log10_mW = log10_temp + exp
        return 10.0 * log10_mW
    
    rx_power_str = values.get("rx_power", "0")
    rx_high_str = values.get("rx_high", "0")
    rx_low_str = values.get("rx_low", "0")
    tx_power_str = values.get("tx_power", "0")
    tx_high_str = values.get("tx_high", "0")
    tx_low_str = values.get("tx_low", "0")
    
    rx_power_dbm = micro_watt_to_dBm(rx_power_str)
    rx_high_dbm = micro_watt_to_dBm(rx_high_str)
    rx_low_dbm = micro_watt_to_dBm(rx_low_str)
    tx_power_dbm = micro_watt_to_dBm(tx_power_str)
    tx_high_dbm = micro_watt_to_dBm(tx_high_str)
    tx_low_dbm = micro_watt_to_dBm(tx_low_str)
    
    rx_ok = rx_power_dbm != -999.0
    tx_ok = tx_power_dbm != -999.0
    
    state = "OK"
    details = ""
    metrics = {}
    
    if rx_ok:
        if rx_power_dbm >= rx_high_dbm or rx_power_dbm <= rx_low_dbm:
            state = "CRIT"
            details += "Receive power (%f dBm) out of range; " % rx_power_dbm
        metrics["input_signal_power_dbm"] = rx_power_dbm
    else:
        details += "Received signal power is 0 watt; "
    
    if tx_ok:
        if tx_power_dbm >= tx_high_dbm or tx_power_dbm <= tx_low_dbm:
            state = "CRIT"
            details += "Transmit power (%f dBm) out of range; " % tx_power_dbm
        metrics["output_signal_power_dbm"] = tx_power_dbm
    else:
        details += "Transmitted signal power is 0 watt; "
    
    if state == "OK":
        msg = "Port %s: rx=%f dBm, tx=%f dBm" % (item, rx_power_dbm if rx_ok else 0, tx_power_dbm if tx_ok else 0)
    else:
        msg = "Port %s: %s" % (item, details.strip("; "))
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
