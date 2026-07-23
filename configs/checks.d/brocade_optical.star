def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.2.2.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        if_info = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            val = parts[1].strip()
            if not oid_val.startswith(".1.3.6.1.2.1.2.2.1."):
                continue
            suffix = oid_val.rsplit(".", 1)[1]
            if suffix in ["1", "2", "3", "8"]:
                if suffix == "1":
                    current_idx = val.strip()
                    if_info[current_idx] = {}
                elif suffix == "2":
                    if current_idx in if_info:
                        if_info[current_idx]["description"] = val.strip('"')
                elif suffix == "3":
                    if current_idx in if_info:
                        if_info[current_idx]["type"] = val.strip('"')
                elif suffix == "8":
                    if current_idx in if_info:
                        if_info[current_idx]["oper_status"] = val

        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.1991.1.1.3.3.6.1"
        ], mutates=False)
        if_data = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            val = parts[1].strip()
            if not oid_val.startswith(".1.3.6.1.4.1.1991.1.1.3.3.6.1."):
                continue
            suffix = oid_val.rsplit(".", 1)[1]
            if suffix in ["1", "2", "3"]:
                if_id = oid_val.rsplit(".", 2)[1]
                val_stripped = val.strip().rstrip('"')
                if if_id not in if_data:
                    if_data[if_id] = {}
                if suffix == "1":
                    if_data[if_id]["temp"] = val_stripped
                elif suffix == "2":
                    if_data[if_id]["tx_light"] = val_stripped
                elif suffix == "3":
                    if_data[if_id]["rx_light"] = val_stripped

        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.1991.1.1.3.3.9.1"
        ], mutates=False)
        media_data = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            val = parts[1].strip()
            if not oid_val.startswith(".1.3.6.1.4.1.1991.1.1.3.3.9.1."):
                continue
            suffix = oid_val.rsplit(".", 1)[1]
            if suffix in ["1", "4", "5"]:
                if_id = oid_val.rsplit(".", 2)[1]
                val_stripped = val.strip().rstrip('"')
                if if_id not in media_data:
                    media_data[if_id] = {}
                if suffix == "1":
                    media_data[if_id]["type"] = val_stripped
                elif suffix == "4":
                    media_data[if_id]["part"] = val_stripped
                elif suffix == "5":
                    media_data[if_id]["serial"] = val_stripped

        out = []
        for if_id, info in if_info.items():
            if if_id in if_data or if_id in media_data:
                params_for_item = {
                    "temp": False,
                    "tx_light": False,
                    "rx_light": False,
                    "lanes": False
                }
                metrics = ["tx_light", "rx_light"]
                if if_id in if_data and "temp" in if_data[if_id]:
                    metrics.append("temp")
                out.append({
                    "item": if_id,
                    "params": params_for_item,
                    "metrics": metrics
                })

        return {"changed": False, "msg": "discovered %d optical ports" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "").lstrip("0")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.2.1.2.2.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if_info = None
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_val = parts[0].strip()
        val = parts[1].strip()
        if not oid_val.startswith(".1.3.6.1.2.1.2.2.1."):
            continue
        suffix = oid_val.rsplit(".", 1)[1]
        if suffix == "1":
            idx = val.strip()
            if idx == item or idx.lstrip("0") == item.lstrip("0"):
                if_info = {"ifIndex": idx}
        elif if_info != None:
            if suffix == "2":
                if_info["description"] = val.strip('"')
            elif suffix == "3":
                if_info["type"] = val.strip('"')
            elif suffix == "8":
                if_info["oper_status"] = val
                break
    
    if if_info == None:
        return {"changed": False, "msg": "interface not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.1991.1.1.3.3.6.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    optical_data = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_val = parts[0].strip()
        val = parts[1].strip()
        if not oid_val.startswith(".1.3.6.1.4.1.1991.1.1.3.3.6.1."):
            continue
        suffix = oid_val.rsplit(".", 1)[1]
        if suffix in ["1", "2", "3"]:
            if_id = oid_val.rsplit(".", 2)[1]
            if if_id == item or if_id.lstrip("0") == item.lstrip("0"):
                val_stripped = val.strip().rstrip('"')
                if suffix == "1":
                    optical_data["temp"] = val_stripped
                elif suffix == "2":
                    optical_data["tx_light"] = val_stripped
                elif suffix == "3":
                    optical_data["rx_light"] = val_stripped
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.1991.1.1.3.3.9.1"
    ], mutates=False)
    media_data = {}
    if res.rc == 0:
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            val = parts[1].strip()
            if not oid_val.startswith(".1.3.6.1.4.1.1991.1.1.3.3.9.1."):
                continue
            suffix = oid_val.rsplit(".", 1)[1]
            if suffix in ["1", "4", "5"]:
                if_id = oid_val.rsplit(".", 2)[1]
                if if_id == item or if_id.lstrip("0") == item.lstrip("0"):
                    val_stripped = val.strip().rstrip('"')
                    if suffix == "1":
                        media_data["type"] = val_stripped
                    elif suffix == "4":
                        media_data["part"] = val_stripped
                    elif suffix == "5":
                        media_data["serial"] = val_stripped
    
    def parse_value(val_str):
        if val_str == "N/A" or val_str.lower() == "not supported":
            return None, None
        parts = val_str.split()
        if len(parts) >= 3:
            val_part = parts[0]
            status_part = parts[2]
            if val_part.lstrip('-').replace('.','').isdigit():
                return float(val_part), status_part
        return None, None
    
    add_info = []
    if "serial" in media_data:
        add_info.append("S/N " + media_data["serial"])
    if "part" in media_data:
        add_info.append("P/N " + media_data["part"])
    
    oper_status_map = {
        "1": "up", "2": "down", "3": "testing", "4": "unknown",
        "5": "dormant", "6": "not present", "7": "lower layer down",
        "8": "degraded", "9": "admin down"
    }
    oper_status = if_info.get("oper_status", "4")
    oper_status_readable = oper_status_map.get(oper_status, "unknown[%s]" % oper_status)
    
    msg_parts = ["Operational %s" % oper_status_readable]
    if len(add_info) > 0:
        msg_parts[0] = "[{}] ".format(", ".join(add_info)) + msg_parts[0]
    
    state = "OK"
    metrics = {}
    
    temp_val, temp_status = parse_value(optical_data.get("temp", "N/A Normal"))
    if temp_val != None:
        temp_warn = params.get("temp_warn", 70.0)
        temp_crit = params.get("temp_crit", 80.0)
        if temp_val >= temp_crit:
            state = "CRIT"
        elif temp_val >= temp_warn:
            if state != "CRIT":
                state = "WARN"
        metrics["temperature"] = temp_val
    
    tx_val, tx_status = parse_value(optical_data.get("tx_light", "N/A Normal"))
    if tx_val != None:
        tx_warn = params.get("tx_light_warn", -10.0)
        tx_crit = params.get("tx_light_crit", -20.0)
        if tx_val <= tx_crit:
            state = "CRIT"
        elif tx_val <= tx_warn:
            if state != "CRIT":
                state = "WARN"
        metrics["tx_light"] = tx_val
    
    rx_val, rx_status = parse_value(optical_data.get("rx_light", "N/A Normal"))
    if rx_val != None:
        rx_warn = params.get("rx_light_warn", -10.0)
        rx_crit = params.get("rx_light_crit", -20.0)
        if rx_val <= rx_crit:
            state = "CRIT"
        elif rx_val <= rx_warn:
            if state != "CRIT":
                state = "WARN"
        metrics["rx_light"] = rx_val
    
    if state == "OK":
        details = ""
    else:
        details = ""
    
    return {"changed": False, "msg": "; ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": details}}