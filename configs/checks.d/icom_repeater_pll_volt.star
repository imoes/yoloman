def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.2021.8.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        # Parse raw SNMP output into a section-like dict
        section = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            val_part = parts[1].strip()
            # Extract value (type: value format)
            if ": " in val_part:
                val_str = val_part.split(": ", 1)[1]
            else:
                val_str = val_part
            
            # Parse relevant fields — mimic parse_icom_repeater logic
            if "ESN number" in val_str and val_str.startswith("String: "):
                section["esnno"] = val_str[8:]
            elif "Temperature" in val_str and val_str.startswith("String: "):
                temp_raw = val_str[8:]
                if temp_raw.endswith("C"):
                    temp_val = temp_raw[:-1]
                    if temp_val.replace(".", "", 1).isdigit() or (temp_val.startswith("-") and temp_val[1:].replace(".", "", 1).isdigit()):
                        section["temp"] = float(temp_val)
                        section["temp_devunit"] = "c"
            elif "Repeater operation" in val_str:
                section["repop"] = val_str.lower()
            elif "Abnormal temperature detection" in val_str:
                if val_str.find("Not detected") != -1:
                    section["temp_devstatus"] = 0
                elif val_str.find("detected") != -1:
                    section["temp_devstatus"] = 2
            elif "Power-supply voltage" in val_str:
                ps_raw = val_str
                if ps_raw.endswith("V"):
                    ps_val = ps_raw[:-1]
                    if ps_val.replace(".", "", 1).isdigit() or (ps_val.startswith("-") and ps_val[1:].replace(".", "", 1).isdigit()):
                        section["ps_voltage"] = float(ps_val)
            elif "Abnormal power-supply voltage detection" in val_str:
                if val_str.find("Not detected") != -1:
                    section["ps_volt_devstatus"] = 0
                elif val_str.find("detected") != -1:
                    section["ps_volt_devstatus"] = 2
            elif "TX PLL lock voltage" in val_str:
                tx_raw = val_str
                if tx_raw.endswith("V"):
                    tx_val = tx_raw[:-1]
                    if tx_val.replace(".", "", 1).isdigit() or (tx_val.startswith("-") and tx_val[1:].replace(".", "", 1).isdigit()):
                        section["tx_pll_lock_voltage"] = float(tx_val)
            elif "RX PLL lock voltage" in val_str:
                rx_raw = val_str
                if rx_raw.endswith("V"):
                    rx_val = rx_raw[:-1]
                    if rx_val.replace(".", "", 1).isdigit() or (rx_val.startswith("-") and rx_val[1:].replace(".", "", 1).isdigit()):
                        section["rx_pll_lock_voltage"] = float(rx_val)
            elif "Repeater frequency" in val_str:
                freq_dict = {}
                pairs = val_str.split(",")
                for pair in pairs:
                    pair = pair.strip()
                    if pair.find(":") != -1:
                        k, v = pair.split(":", 1)
                        k = k.strip().lower()
                        v = v.strip()
                        if v.replace(".", "", 1).isdigit() or (v.startswith("-") and v[1:].replace(".", "", 1).isdigit()):
                            freq_dict[k] = int(float(v))
                section["repeater_frequency"] = freq_dict
        
        items = []
        if "rx_pll_lock_voltage" in section:
            items.append({"item": "RX", "params": {}, "metrics": ["voltage"]})
        if "tx_pll_lock_voltage" in section:
            items.append({"item": "TX", "params": {}, "metrics": ["voltage"]})
        
        return {"changed": False, "msg": "discovered %d PLL voltage services" % len(items), "data": {"discovery": items}}
    
    item = params.get("item", "")
    if item != "RX" and item != "TX":
        return {"changed": False, "msg": "unknown item", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.2021.8.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_val = parts[0].strip()
        val_part = parts[1].strip()
        if ": " in val_part:
            val_str = val_part.split(": ", 1)[1]
        else:
            val_str = val_part
        
        if "ESN number" in val_str and val_str.startswith("String: "):
            section["esnno"] = val_str[8:]
        elif "Temperature" in val_str and val_str.startswith("String: "):
            temp_raw = val_str[8:]
            if temp_raw.endswith("C"):
                temp_val = temp_raw[:-1]
                if temp_val.replace(".", "", 1).isdigit() or (temp_val.startswith("-") and temp_val[1:].replace(".", "", 1).isdigit()):
                    section["temp"] = float(temp_val)
                    section["temp_devunit"] = "c"
        elif "Repeater operation" in val_str:
            section["repop"] = val_str.lower()
        elif "Abnormal temperature detection" in val_str:
            if val_str.find("Not detected") != -1:
                section["temp_devstatus"] = 0
            elif val_str.find("detected") != -1:
                section["temp_devstatus"] = 2
        elif "Power-supply voltage" in val_str:
            ps_raw = val_str
            if ps_raw.endswith("V"):
                ps_val = ps_raw[:-1]
                if ps_val.replace(".", "", 1).isdigit() or (ps_val.startswith("-") and ps_val[1:].replace(".", "", 1).isdigit()):
                    section["ps_voltage"] = float(ps_val)
        elif "Abnormal power-supply voltage detection" in val_str:
            if val_str.find("Not detected") != -1:
                section["ps_volt_devstatus"] = 0
            elif val_str.find("detected") != -1:
                section["ps_volt_devstatus"] = 2
        elif "TX PLL lock voltage" in val_str:
            tx_raw = val_str
            if tx_raw.endswith("V"):
                tx_val = tx_raw[:-1]
                if tx_val.replace(".", "", 1).isdigit() or (tx_val.startswith("-") and tx_val[1:].replace(".", "", 1).isdigit()):
                    section["tx_pll_lock_voltage"] = float(tx_val)
        elif "RX PLL lock voltage" in val_str:
            rx_raw = val_str
            if rx_raw.endswith("V"):
                rx_val = rx_raw[:-1]
                if rx_val.replace(".", "", 1).isdigit() or (rx_val.startswith("-") and rx_val[1:].replace(".", "", 1).isdigit()):
                    section["rx_pll_lock_voltage"] = float(rx_val)
        elif "Repeater frequency" in val_str:
            freq_dict = {}
            pairs = val_str.split(",")
            for pair in pairs:
                pair = pair.strip()
                if pair.find(":") != -1:
                    k, v = pair.split(":", 1)
                    k = k.strip().lower()
                    v = v.strip()
                    if v.replace(".", "", 1).isdigit() or (v.startswith("-") and v[1:].replace(".", "", 1).isdigit()):
                        freq_dict[k] = int(float(v))
            section["repeater_frequency"] = freq_dict
    
    freq_key = item.lower() + "_pll_lock_voltage"
    if not section.get("repeater_frequency", {}).get(item.lower(), 0) or not section.get(freq_key):
        return {"changed": False, "msg": "missing data for %s PLL lock voltage" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    voltage = section[freq_key]
    freq = section["repeater_frequency"].get(item.lower(), 0)
    
    paramlist = params.get(item.lower(), None)
    
    if paramlist == None or type(paramlist) != "list" or len(paramlist) == 0:
        return {"changed": False, "msg": "Please specify parameters for %s PLL voltage" % item,
                "data": {"state": "WARN", "metrics": {"voltage": voltage}, "details": ""}}
    
    # Find row with freq_threshold >= freq
    warn_lower = 0.0
    crit_lower = 0.0
    warn = 0.0
    crit = 0.0
    found = False
    
    for i in range(len(paramlist)):
        row = paramlist[i]
        if len(row) < 4:
            continue
        freq_threshold = row[0]
        if freq_threshold >= freq:
            if i > 0:
                prev_row = paramlist[i - 1]
                if len(prev_row) >= 5:
                    warn_lower, crit_lower, warn, crit = prev_row[1], prev_row[2], prev_row[3], prev_row[4]
                else:
                    warn_lower, crit_lower, warn, crit = prev_row[1], prev_row[2], prev_row[3], prev_row[3]
            else:
                # No previous row — use current
                warn_lower, crit_lower, warn, crit = row[1], row[2], row[3], row[3]
            found = True
            break
    
    if not found:
        # Use last row
        last_row = paramlist[-1]
        if len(last_row) >= 5:
            warn_lower, crit_lower, warn, crit = last_row[1], last_row[2], last_row[3], last_row[4]
        elif len(last_row) >= 4:
            warn_lower, crit_lower, warn, crit = last_row[1], last_row[2], last_row[3], last_row[3]
        else:
            return {"changed": False, "msg": "malformed params row",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # State determination
    if voltage < crit_lower or voltage >= crit:
        status = 2
    elif voltage < warn_lower or voltage >= warn:
        status = 1
    else:
        status = 0
    
    infotext = "%f V" % voltage
    levelstext = " (warn/crit below %f/%f V and at or above %f/%f V)" % (warn_lower, crit_lower, warn, crit)
    if status != 0:
        infotext += levelstext
    
    return {"changed": False, "msg": infotext,
            "data": {"state": "CRIT" if status == 2 else ("WARN" if status == 1 else "OK"),
                     "metrics": {"voltage": voltage}, "details": ""}}