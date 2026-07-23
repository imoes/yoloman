def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 4 services",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []},
                    {"item": "SyncModuleTimeSyncState", "params": {}, "metrics": []},
                    {"item": "ntpSysStratum", "params": {}, "metrics": []},
                    {"item": "SyncModuleTimeLocal", "params": {}, "metrics": []},
                ]
            },
        }

    item = params.get("item", "")

    def _get_time(timefromdevice):
        if not timefromdevice:
            return ""
        length = len(timefromdevice)
        if length == 8:
            b = timefromdevice.encode("latin-1")
            if len(b) < 8:
                return ""
            y = ord(b[0]) * 256 + ord(b[1])
            m = ord(b[2])
            d = ord(b[3])
            h = ord(b[4])
            mi = ord(b[5])
            s = ord(b[6])
            return "%d-%d-%d %d:%d:%d" % (y, m, d, h, mi, s)
        elif length == 11:
            b = timefromdevice.encode("latin-1")
            if len(b) < 11:
                return ""
            y = ord(b[0]) * 256 + ord(b[1])
            m = ord(b[2])
            d = ord(b[3])
            h = ord(b[4])
            mi = ord(b[5])
            s = ord(b[6])
            sign_byte = ord(b[7])
            sign = '-' if sign_byte & 0x80 else '+'
            offset_hours = sign_byte & 0x7f
            offset_mins = ord(b[8])
            return "%d-%d-%d %d:%d:%d %c%d:%d" % (y, m, d, h, mi, s, sign, offset_hours, offset_mins)
        return ""

    def parse_hepta_section(snmp_data):
        if not snmp_data or not any(snmp_data):
            return None
        raw = snmp_data[0] or snmp_data[1]
        if len(raw) < 8:
            return None
        return {
            "devicetype": raw[0],
            "serialnumber": raw[1],
            "firmwareversion": raw[2],
            "firmwaredate": _get_time(raw[3]),
            "version": raw[4],
            "ntpstratum": raw[5],
            "syncmoduletimesyncstate": raw[6],
            "syncmoduletimelocal": _get_time(raw[7]),
        }

    def parse_snmpwalk_output(res_stdout):
        result = []
        if not res_stdout:
            return result
        lines = res_stdout.splitlines()
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                val = parts[1].strip()
                if ": " in val:
                    val = val.split(": ", 1)[1].strip()
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                result.append(val)
            else:
                result.append("")
        return result

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    tree1 = [
        ".1.3.6.1.4.1.12527.29.1.1.0",
        ".1.3.6.1.4.1.12527.29.1.3.0",
        ".1.3.6.1.4.1.12527.29.1.4.0",
        ".1.3.6.1.4.1.12527.29.1.5.0",
        ".1.3.6.1.4.1.12527.29.1.6.0",
        ".1.3.6.1.4.1.12527.29.2.1.2.0",
        ".1.3.6.1.4.1.12527.29.3.1.0",
        ".1.3.6.1.4.1.12527.29.3.5.0",
    ]
    tree2 = [
        ".1.3.6.1.4.1.12527.40.1.1.0",
        ".1.3.6.1.4.1.12527.40.1.3.0",
        ".1.3.6.1.4.1.12527.40.1.4.0",
        ".1.3.6.1.4.1.12527.40.1.5.0",
        ".1.3.6.1.4.1.12527.40.1.6.0",
        ".1.3.6.1.4.1.12527.40.2.1.2.0",
        ".1.3.6.1.4.1.12527.40.3.1.0",
        ".1.3.6.1.4.1.12527.40.3.5.0",
    ]

    res1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + tree1, mutates=False)
    res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + tree2, mutates=False)

    data1 = parse_snmpwalk_output(res1.stdout) if res1.rc == 0 else []
    data2 = parse_snmpwalk_output(res2.stdout) if res2.rc == 0 else []

    section = parse_hepta_section([data1, data2])
    if section == None:
        if item == "" or item == "SyncModuleTimeSyncState" or item == "ntpSysStratum" or item == "SyncModuleTimeLocal":
            return {
                "changed": False,
                "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    if item == "" or item == "HPF Info":
        if item != "" and item != "HPF Info":
            return {
                "changed": False,
                "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        summary = (
            "DeviceType " + section["devicetype"] + " ; " +
            "SerialNumber " + section["serialnumber"] + " ; " +
            "FirmwareVersion " + section["firmwareversion"] + " ; " +
            "FirmwareDate " + section["firmwaredate"] + " ; " +
            "Version " + section["version"]
        )
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    elif item == "SyncModuleTimeSyncState":
        state = section["syncmoduletimesyncstate"]
        if state == "R":
            summary = "Radio synchronous with high precision"
            state_code = "OK"
        elif state == "r":
            summary = "Radio synchronous with low precision"
            state_code = "WARN"
        elif state == "C":
            summary = "Crystal"
            state_code = "CRIT"
        elif state == "I":
            summary = "Invalid time and date"
            state_code = "CRIT"
        else:
            summary = "No data available"
            state_code = "UNKNOWN"
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": state_code, "metrics": {}, "details": ""},
        }

    elif item == "ntpSysStratum":
        stratum = section["ntpstratum"]
        if stratum == "1":
            summary = "Stratum 1, Primary Reference "
            state = "OK"
        elif stratum == "16":
            summary = "Stratum Invalid"
            state = "CRIT"
        elif stratum == "0":
            summary = "Stratum Unknown"
            state = "UNKNOWN"
        else:
            summary = "Stratum is using secondary reference(via NTP)"
            state = "WARN"
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""},
        }

    elif item == "SyncModuleTimeLocal":
        summary = "Module Time: " + section["syncmoduletimelocal"]
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "no such item: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }