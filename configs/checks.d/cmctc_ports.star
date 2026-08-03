# cmctc_ports — Checkmk SNMP check translation (read-only Starlark module)

def _get_ports(ctx, host, community):
    type_map = {
        "1": "not available",
        "2": "IO",
        "3": "Access",
        "4": "Climate",
        "5": "FCS",
        "6": "RTT",
        "7": "RTC",
        "8": "PSM",
        "9": "PSM8",
        "10": "PSM metered",
        "11": "IO wireless",
        "12": "PSM6 Schuko",
        "13": "PSM6C19",
        "14": "Fuel Cell",
        "15": "DRC",
        "16": "TE cooler",
        "17": "PSM32 metered",
        "18": "PSM8x8",
        "19": "PSM6x6 Schuko",
        "20": "PSM6x6C19",
    }
    status_map = {
        "1": "ok",
        "2": "error",
        "3": "configuration changed",
        "4": "quit from sensor unit",
        "5": "timeout",
        "6": "unit detected",
        "7": "not available",
        "8": "supply voltage low",
    }
    units = ["3", "4", "5", "6"]
    port_index_to_info = {}
    for unit in units:
        base = ".1.3.6.1.4.1.2606.4.2." + unit
        cols = ["1", "2", "3", "4"]
        column_values = {}
        for col in cols:
            oid = base + "." + col
            res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                mutates=False,
            )
            if res.rc != 0:
                column_values[col] = None
            else:
                val = res.stdout.strip()
                if val == "":
                    column_values[col] = None
                else:
                    column_values[col] = val
        port_info = [column_values["1"], column_values["2"], column_values["3"], column_values["4"]]
        if port_info[0] != None:
            idx = port_info[0]
            existing = port_index_to_info.get(idx, {})
            existing[unit] = port_info
            port_index_to_info[idx] = existing
    result = {}
    port_index = 0
    for idx in sorted(port_index_to_info.keys()):
        number = idx + 3
        unit_data = port_index_to_info[idx]
        for unit in units:
            port_info = unit_data.get(unit)
            if port_info == None:
                continue
            device_type = port_info[0]
            description = port_info[1]
            serial_number = port_info[2]
            device_status = port_info[3]
            status_text = status_map.get(device_status)
            if status_text == "not available":
                continue
            entry = {
                "type": type_map.get(device_type),
                "status": status_text,
                "serial": serial_number,
            }
            name = "%d %s" % (number, description)
            result[name] = entry
            port_index += 1
    return result


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if params.get("_discover"):
        ports = _get_ports(ctx, host, community)
        discovery = []
        for name in sorted(ports.keys()):
            entry = ports[name]
            discovery.append({
                "item": name,
                "params": {},
                "metrics": [],
                "service_labels": {
                    "cmk/port_type": entry["type"] if entry["type"] != None else "unknown",
                },
            })
        return {
            "changed": False,
            "msg": "discovered %d ports" % len(discovery),
            "data": {"discovery": discovery},
        }
    item = params.get("item", "")
    ports = _get_ports(ctx, host, community)
    port = ports.get(item)
    if port == None:
        return {
            "changed": False,
            "msg": "no such port: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    status_map = {
        "ok": "OK",
        "configuration changed": "WARN",
        "unit detected": "WARN",
        "error": "CRIT",
        "quit from sensor unit": "CRIT",
        "timeout": "CRIT",
        "not available": "CRIT",
        "supply voltage low": "CRIT",
    }
    state = status_map.get(port["status"], "UNKNOWN")
    ptype = port["type"]
    serial = port["serial"]
    infotext = "Status: %s, Device type: %s, Serial number: %s" % (
        port["status"],
        ptype if ptype != None else "unknown",
        serial if serial != None else "unknown",
    )
    return {
        "changed": False,
        "msg": infotext,
        "data": {"state": state, "metrics": {}, "details": infotext},
    }