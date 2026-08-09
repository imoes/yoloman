def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.31770.2.2.8"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        items = []
        lines = res.stdout.splitlines()
        for line in lines:
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid = parts[0]
            if oid.endswith(".1.64.4.255.2.1.0"):
                oids = oid.split(".")
                idx = len(oids) - 10
                if idx >= 0:
                    if oids[idx:idx+10] == ["0","1","64","4","255","2","1","0"]:
                        pdu_num_str = oids[idx-1]
                        if pdu_num_str.isdigit():
                            pdu_num = int(pdu_num_str)
                            if pdu_num == 0:
                                pdu_name = "Master"
                            else:
                                pdu_name = "PDU " + str(pdu_num)
                            sensor_name = "Sensor " + pdu_name + " 1/255"
                            items.append({"item": sensor_name, "params": {"warn": 30.0, "crit": 35.0},
                                          "metrics": ["temp"]})

        return {"changed": False, "msg": "discovered %d temperature sensors" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    base_oid = ".1.3.6.1.4.1.31770.2.2.8.4.1.5"

    if item.startswith("Sensor Master "):
        pdu_part = "0"
    elif item.startswith("Sensor PDU "):
        parts_item = item.split(" ")
        if len(parts_item) >= 3:
            pdu_part = parts_item[2]
        else:
            return {"changed": False, "msg": "invalid item format", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "invalid item format", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_oid = base_oid + "." + pdu_part + ".1.64.4.255.2.1.0"

    res_temp = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, sensor_oid
    ], mutates=False)

    if res_temp.rc != 0 or res_temp.stdout.strip().endswith("No Such Object"):
        return {"changed": False, "msg": "temperature sensor not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_parts = res_temp.stdout.strip().split()
    if len(temp_parts) < 2:
        return {"changed": False, "msg": "cannot parse temperature value", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp_str = temp_parts[-1].strip()
    if not temp_str:
        return {"changed": False, "msg": "cannot parse temperature value", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temp = float(temp_str)

    status_oid = base_oid.replace(".5.", ".7.") + "." + pdu_part + ".1.64.4.255.2.1.0"
    res_status = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, status_oid
    ], mutates=False)

    state = "OK"
    state_readable = "OK"
    if res_status.rc == 0 and not res_status.stdout.strip().endswith("No Such Object"):
        status_parts = res_status.stdout.strip().split()
        if len(status_parts) >= 2:
            status_val_str = status_parts[-1].strip()
            if status_val_str.isdigit():
                status_val = int(status_val_str)
                status_map = {
                    0: (0, "expected"),
                    1: (3, "undefined"),
                    2: (0, "OK"),
                    3: (2, "error high"),
                    4: (2, "error low"),
                    5: (1, "warning high"),
                    6: (1, "warning low"),
                    7: (2, "lost"),
                }
                status_info = status_map.get(status_val, (0, "OK"))
                state = "CRIT" if status_info[0] == 2 else ("WARN" if status_info[0] == 1 else "OK")
                state_readable = status_info[1]

    warn = params.get("warn", 30.0)
    crit = params.get("crit", 35.0)

    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    msg = "Temperature %s: %f C" % (item, temp)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temp": temp}, "details": state_readable}}
