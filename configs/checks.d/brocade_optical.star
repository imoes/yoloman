def _parse_value(value_string):
    s = value_string.strip()
    if s == "N/A" or s.lower() == "not supported":
        return [None, None]
    parts = s.split(" ")
    if len(parts) >= 3:
        val = parts[0]
        num_str = val.lstrip("-").replace(".", "")
        if num_str != "" and num_str.isdigit():
            v = float(val)
            status = parts[2]
            return [v, status]
    return [None, None]

def _walk_table(ctx, host, community, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    entries = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid_part = line[:sp]
        val_part = line[sp + 1:]
        if not oid_part.startswith(column_oid + "."):
            continue
        index = oid_part[len(column_oid) + 1:]
        if index == "":
            continue
        entries[index] = val_part
    return entries

def _gather_section(ctx, host, community):
    if_info_descr = _walk_table(ctx, host, community, ".1.3.6.1.2.1.2.2.1.2")
    if_info_type = _walk_table(ctx, host, community, ".1.3.6.1.2.1.2.2.1.3")
    if_info_oper = _walk_table(ctx, host, community, ".1.3.6.1.2.1.2.2.1.8")
    data1_res = _walk_table(ctx, host, community, ".1.3.6.1.4.1.1991.1.1.3.3.6.1.1")
    data2_res = _walk_table(ctx, host, community, ".1.3.6.1.4.1.1991.1.1.3.3.6.1.2")
    data3_res = _walk_table(ctx, host, community, ".1.3.6.1.4.1.1991.1.1.3.3.6.1.3")
    section = {}
    for index in if_info_descr:
        entry = {}
        entry["temp"] = _parse_value(data1_res.get(index, "N/A"))
        entry["tx_light"] = _parse_value(data2_res.get(index, "N/A"))
        entry["rx_light"] = _parse_value(data3_res.get(index, "N/A"))
        entry["port_type"] = if_info_type.get(index, "")
        entry["description"] = if_info_descr[index]
        entry["operational_status"] = if_info_oper.get(index, "")
        section[index] = entry
    ids1 = _walk_table(ctx, host, community, ".1.3.6.1.4.1.1991.1.1.3.3.9.1.1")
    ids4 = _walk_table(ctx, host, community, ".1.3.6.1.4.1.1991.1.1.3.3.9.1.4")
    ids5 = _walk_table(ctx, host, community, ".1.3.6.1.4.1.1991.1.1.3.3.9.1.5")
    for index in section:
        section[index]["type"] = ids1.get(index, "")
        section[index]["part"] = ids4.get(index, "")
        section[index]["serial"] = ids5.get(index, "")
    lane_temp = _walk_table(ctx, host, community, ".1.3.6.1.4.1.1991.1.1.3.3.10.1.2")
    lane_tx = _walk_table(ctx, host, community, ".1.3.6.1.4.1.1991.1.1.3.3.10.1.3")
    lane_rx = _walk_table(ctx, host, community, ".1.3.6.1.4.1.1991.1.1.3.3.10.1.4")
    lanes_by_port = {}
    for oid_index, val in lane_temp.items():
        if "." not in oid_index:
            continue
        port_id, lane_str = oid_index.rsplit(".", 1)
        if not lane_str.isdigit():
            continue
        lane_num = int(lane_str)
        lane_entry = {
            "temp": _parse_value(val),
            "tx_light": _parse_value(lane_tx.get(oid_index, "N/A")),
            "rx_light": _parse_value(lane_rx.get(oid_index, "N/A")),
        }
        lanes_by_port.setdefault(port_id, {})[lane_num] = lane_entry
    for port_id, lanes in lanes_by_port.items():
        if port_id in section:
            section[port_id]["lanes"] = lanes
    return section

def _monitoring_state(reading, temp_alert):
    if reading[0] == None:
        return 3
    if temp_alert:
        status = reading[1].lower()
        if status == "normal":
            return 0
        if status.endswith("warn"):
            return 1
        return 2
    return 0

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if params.get("_discover"):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "not a brocade mlx device",
                    "data": {"discovery": []}}
        sys_oid = res.stdout.strip()
        if not sys_oid:
            return {"changed": False, "msg": "no sysOid",
                    "data": {"discovery": []}}
        if not sys_oid.startswith(".1.3.6.1.4.1.1991.1."):
            return {"changed": False, "msg": "not a brocade mlx device",
                    "data": {"discovery": []}}
        if_info_descr = _walk_table(ctx, host, community, ".1.3.6.1.2.1.2.2.1.2")
        items = []
        for index in if_info_descr:
            items.append({
                "item": index,
                "params": {"temp_warn": 60, "temp_crit": 80,
                           "tx_warn": -3, "tx_crit": -6,
                           "rx_warn": -3, "rx_crit": -6,
                           "temp": False, "tx_light": False, "rx_light": False,
                           "lanes": False},
                "metrics": ["temp", "tx_light", "rx_light"],
            })
        return {"changed": False,
                "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    item = params.get("item", "")
    section = _gather_section(ctx, host, community)
    if item not in section:
        return {"changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    iface = section[item]
    metrics = {}
    details = []
    state = "OK"
    oper = iface.get("operational_status", "")
    oper_map = {
        "1": "up", "2": "down", "3": "testing", "4": "unknown",
        "5": "dormant", "6": "not present", "7": "lower layer down",
        "8": "degraded", "9": "admin down",
    }
    oper_readable = oper_map.get(oper, "unknown[" + str(oper) + "]")
    if oper_readable != "up":
        state = "WARN"
    if iface.get("serial"):
        details.append("S/N " + iface["serial"])
    if iface.get("part"):
        details.append("P/N " + iface["part"])
    details.append("Operational " + oper_readable)
    temp = iface.get("temp")
    if temp[0] != None:
        metrics["temp"] = temp[0]
        t_state = _monitoring_state(temp, params.get("temp", False))
        if t_state == 1:
            state = "WARN"
        elif t_state == 2:
            state = "CRIT"
        details.append("Temperature %f C (%s)" % (temp[0], temp[1]))
    tx = iface.get("tx_light")
    if tx[0] != None:
        metrics["tx_light"] = tx[0]
        tx_state = _monitoring_state(tx, params.get("tx_light", False))
        if tx_state == 1:
            state = "WARN"
        elif tx_state == 2:
            state = "CRIT"
        details.append("TX Light %f dBm (%s)" % (tx[0], tx[1]))
    rx = iface.get("rx_light")
    if rx[0] != None:
        metrics["rx_light"] = rx[0]
        rx_state = _monitoring_state(rx, params.get("rx_light", False))
        if rx_state == 1:
            state = "WARN"
        elif rx_state == 2:
            state = "CRIT"
        details.append("RX Light %f dBm (%s)" % (rx[0], rx[1]))
    if params.get("lanes") and iface.get("lanes"):
        for num, lane in iface["lanes"].items():
            lt = lane["temp"]
            if lt[0] != None:
                metrics["port_temp_" + str(num)] = lt[0]
            ltx = lane["tx_light"]
            if ltx[0] != None:
                metrics["tx_light_" + str(num)] = ltx[0]
            lrx = lane["rx_light"]
            if lrx[0] != None:
                metrics["rx_light_" + str(num)] = lrx[0]
    msg = "; ".join(details)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": "\n".join(details)}}