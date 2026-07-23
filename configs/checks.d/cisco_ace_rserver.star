def main(ctx, params):
    # Discover mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            ".1.3.6.1.4.1.9.9.470.1.1.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        lines = res.stdout.splitlines()
        rows = {}
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid, value = parts
            oid_parts = oid.split(".")
            if len(oid_parts) < 16:
                continue

            idx_str = oid_parts[-1]
            idx = int(idx_str) if idx_str.isdigit() else -1
            if idx < 0:
                continue

            field_str = oid_parts[-2]
            field = int(field_str) if field_str.isdigit() else -1
            if field < 0:
                continue

            value = value.strip()
            if value.startswith("STRING: "):
                val = value[8:]
                if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
                    val = val[1:-1]
                value = val
            elif value.startswith("INTEGER: "):
                val = value[9:]
                value = int(val) if val.isdigit() else 0
            elif value.startswith("OCTET STRING: "):
                hex_str = value[14:]
                if hex_str.startswith('"') and hex_str.endswith('"'):
                    hex_str = hex_str[1:-1]
                bytes_list = []
                for b in hex_str.split():
                    if len(b) >= 2 and b[0] == '0' and (b[1] == 'x' or b[1] == 'X'):
                        # Use a helper pattern: parse hex manually or default
                        hex_val = b[2:]
                        if hex_val.isdigit():
                            bytes_list.append(int(hex_val, 16))
                        else:
                            bytes_list.append(0)
                    elif b.isdigit():
                        bytes_list.append(int(b))
                    else:
                        bytes_list.append(0)
                value = bytes_list
            else:
                value = value

            if idx not in rows:
                rows[idx] = {}
            rows[idx][field] = value

        section = []
        for idx, row in sorted(rows.items()):
            name = row.get(1, "")
            ip_type = row.get(3, 0)
            ip_bytes = row.get(4, [])
            descr = row.get(5, "")
            admin_status = row.get(12, "1")
            oper_status = row.get(13, "1")
            conns = row.get(19, "0")
            if type(conns) == "string":
                conns = int(conns) if conns.isdigit() else 0
            elif type(conns) != "int":
                conns = 0

            section.append([name, ip_type, ip_bytes, descr, admin_status, oper_status, conns])

        out = []
        for entry in section:
            name, ip_type, ip_bytes, descr, admin_status, oper_status, conns = entry
            ip = ""
            if type(ip_type) == "int" and type(ip_bytes) == "list":
                if ip_type == 1 and len(ip_bytes) >= 4:
                    ip = "%d.%d.%d.%d" % (ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3])
                elif ip_type == 2 and len(ip_bytes) >= 8:
                    ip = "%x:%x:%x:%x:%x:%x:%x:%x" % (
                        ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3],
                        ip_bytes[4], ip_bytes[5], ip_bytes[6], ip_bytes[7]
                    )
                elif ip_type == 5 and len(ip_bytes) > 0:
                    ip = "".join([chr(x) for x in ip_bytes])
                elif ip_type == 0 and len(ip_bytes) > 0:
                    ip = "".join(["%x" % byte for byte in ip_bytes])
            item = name if name != "" else (descr if descr != "" else ip)
            if item != "":
                out.append({"item": str(item), "params": {}, "metrics": ["connections"]})

        return {
            "changed": False,
            "msg": "discovered %d rserver(s)" % len(out),
            "data": {"discovery": out},
        }

    # Check mode
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host,
        ".1.3.6.1.4.1.9.9.470.1.1.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr}
        }

    lines = res.stdout.splitlines()
    rows = {}
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid, value = parts
        oid_parts = oid.split(".")
        if len(oid_parts) < 16:
            continue

        idx_str = oid_parts[-1]
        idx = int(idx_str) if idx_str.isdigit() else -1
        if idx < 0:
            continue

        field_str = oid_parts[-2]
        field = int(field_str) if field_str.isdigit() else -1
        if field < 0:
            continue

        value = value.strip()
        if value.startswith("STRING: "):
            val = value[8:]
            if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
                val = val[1:-1]
            value = val
        elif value.startswith("INTEGER: "):
            val = value[9:]
            value = int(val) if val.isdigit() else 0
        elif value.startswith("OCTET STRING: "):
            hex_str = value[14:]
            if hex_str.startswith('"') and hex_str.endswith('"'):
                hex_str = hex_str[1:-1]
            bytes_list = []
            for b in hex_str.split():
                if len(b) >= 2 and b[0] == '0' and (b[1] == 'x' or b[1] == 'X'):
                    hex_val = b[2:]
                    if hex_val.isdigit():
                        bytes_list.append(int(hex_val, 16))
                    else:
                        bytes_list.append(0)
                elif b.isdigit():
                    bytes_list.append(int(b))
                else:
                    bytes_list.append(0)
            value = bytes_list
        else:
            value = value

        if idx not in rows:
            rows[idx] = {}
        rows[idx][field] = value

    section = []
    for idx, row in sorted(rows.items()):
        name = row.get(1, "")
        ip_type = row.get(3, 0)
        ip_bytes = row.get(4, [])
        descr = row.get(5, "")
        admin_status = row.get(12, "1")
        oper_status = row.get(13, "1")
        conns = row.get(19, "0")
        if type(conns) == "string":
            conns = int(conns) if conns.isdigit() else 0
        elif type(conns) != "int":
            conns = 0

        section.append([name, ip_type, ip_bytes, descr, admin_status, oper_status, conns])

    admin_stati = {
        "1": "in service",
        "2": "out of service",
        "3": "in service, standby",
    }
    oper_stati = {
        "1": (2, "out of service"),
        "2": (0, "in service"),
        "3": (2, "failed"),
        "4": (2, "ready to test"),
        "5": (2, "testing"),
        "6": (2, "max connection reached, throttling"),
        "7": (2, "max clients reached, throttling"),
        "8": (2, "dfp throttle"),
        "9": (2, "probe failed"),
        "10": (1, "probe testing"),
        "11": (2, "oper wait"),
        "12": (2, "test wait"),
        "13": (2, "inband probe failed"),
        "14": (2, "return code failed"),
        "15": (2, "arp failed"),
        "16": (1, "standby"),
        "17": (2, "inactive"),
        "18": (2, "max load reached"),
    }
    state_map = {0: "OK", 1: "WARN", 2: "CRIT"}

    for entry in section:
        name, ip_type, ip_bytes, descr, admin_status, oper_status, conns = entry
        ip_addr = ""
        if type(ip_type) == "int" and type(ip_bytes) == "list":
            if ip_type == 1 and len(ip_bytes) >= 4:
                ip_addr = "%d.%d.%d.%d" % (ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3])
            elif ip_type == 2 and len(ip_bytes) >= 8:
                ip_addr = "%x:%x:%x:%x:%x:%x:%x:%x" % (
                    ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3],
                    ip_bytes[4], ip_bytes[5], ip_bytes[6], ip_bytes[7]
                )
            elif ip_type == 5 and len(ip_bytes) > 0:
                ip_addr = "".join([chr(x) for x in ip_bytes])
            elif ip_type == 0 and len(ip_bytes) > 0:
                ip_addr = "".join(["%x" % byte for byte in ip_bytes])

        if item == name or item == ip_addr or item == descr:
            admin_state = admin_stati.get(admin_status, "unknown")
            oper_tuple = oper_stati.get(str(oper_status), (2, "unknown"))
            state_code, state_txt = oper_tuple
            if admin_status == "2" and state_code == 2:
                state_code = 1
            state = state_map[state_code]
            infotext = "Operational State: %s, Administrative State: %s, Current Connections: %d" % (
                state_txt, admin_state, conns
            )
            return {
                "changed": False,
                "msg": infotext,
                "data": {"state": state, "metrics": {"connections": conns}, "details": ""}
            }

    return {
        "changed": False,
        "msg": "rserver not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }