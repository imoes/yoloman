SERVICE_ID_LOWER_V9 = {
    "1": "dhcp", "2": "dns", "3": "ntp", "4": "tftp", "5": "http-file-dist",
    "6": "ftp", "7": "bloxtools-move", "8": "bloxtools", "9": "node-status",
    "10": "disk-usage", "11": "enet-lan", "12": "enet-lan2", "13": "enet-ha",
    "14": "enet-mgmt", "15": "lcd", "16": "memory", "17": "replication",
    "18": "db-object", "19": "raid-summary", "20": "raid-disk1",
    "21": "raid-disk2", "22": "raid-disk3", "23": "raid-disk4",
    "24": "raid-disk5", "25": "raid-disk6", "26": "raid-disk7",
    "27": "raid-disk8", "28": "fan1", "29": "fan2", "30": "fan3",
    "31": "fan4", "32": "fan5", "33": "fan6", "34": "fan7", "35": "fan8",
    "36": "power-supply1", "37": "power-supply2", "38": "ntp-sync",
    "39": "cpu1-temp", "40": "cpu2-temp", "41": "sys-temp",
    "42": "raid-battery", "43": "cpu-usage", "44": "ospf", "45": "bgp",
    "46": "mgm-service", "47": "subgrid-conn", "48": "network-capacity",
    "49": "reporting", "50": "dns-cache-acceleration", "51": "ospf6",
    "52": "swap-usage", "53": "discovery-consolidator",
    "54": "discovery-collector", "55": "discovery-capacity",
    "56": "threat-protection", "57": "cloud-api", "58": "threat-analytics",
    "59": "taxii", "60": "bfd", "61": "outbound",
}

SERVICE_ID_V9 = {
    "1": "dhcp", "2": "dns", "3": "ntp", "4": "tftp", "5": "http-file-dist",
    "6": "ftp", "7": "node-status", "8": "disk-usage", "9": "enet-lan",
    "10": "enet-lan2", "11": "enet-ha", "12": "enet-mgmt", "13": "memory",
    "14": "replication", "15": "db-object", "16": "raid-summary",
    "17": "raid-disk1", "18": "raid-disk2", "19": "raid-disk3",
    "20": "raid-disk4", "21": "raid-disk5", "22": "raid-disk6",
    "23": "raid-disk7", "24": "raid-disk8", "25": "fan1", "26": "fan2",
    "27": "fan3", "28": "fan4", "29": "fan5", "30": "fan6", "31": "fan7",
    "32": "fan8", "33": "power-supply1", "34": "power-supply2",
    "35": "ntp-sync", "36": "cpu1-temp", "37": "cpu2-temp", "38": "sys-temp",
    "39": "raid-battery", "40": "cpu-usage", "41": "ospf", "42": "bgp",
    "43": "mgm-service", "44": "subgrid-conn", "45": "network-capacity",
    "46": "reporting", "47": "dns-cache-acceleration", "48": "ospf6",
    "49": "swap-usage", "50": "discovery-consolidator",
    "51": "discovery-collector", "52": "discovery-capacity",
    "53": "threat-protection", "54": "cloud-api", "55": "threat-analytics",
    "56": "taxii", "57": "bfd", "58": "outbound",
}

STATUS_ID = {
    "1": "working", "2": "warning", "3": "failed", "4": "inactive", "5": "unknown",
}

STATUS_STATE = {
    "working": "OK", "warning": "WARN", "failed": "CRIT", "unexpected": "UNKNOWN",
}

def _snmp_val(raw):
    idx = raw.find(": ")
    if idx < 0:
        return raw.strip()
    val = raw[idx + 2:].strip()
    if val.startswith('"') and val.endswith('"'):
        return val[1:-1]
    return val

def _walk_col(ctx, host, community, base):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, base],
        mutates=False,
        ok_codes=[0, 1],
    )
    out = {}
    prefix = base + "."
    for line in res.stdout.splitlines():
        eq = line.find(" = ")
        if eq < 0:
            continue
        oid = line[:eq]
        val = _snmp_val(line[eq + 3:])
        if oid.startswith(prefix):
            out[oid[len(prefix):]] = val
    return out

def _get_version_major(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-On", host,
         ".1.3.6.1.4.1.7779.3.1.1.2.1.7.0"],
        mutates=False,
        ok_codes=[0, 1],
    )
    if not res.stdout:
        return None
    ver = _snmp_val(res.stdout.strip())
    parts = ver.split("-")[0].split(".")
    if len(parts) < 1 or not parts[0].isdigit():
        return None
    return int(parts[0])

def _get_services(ctx, host, community):
    major = _get_version_major(ctx, host, community)
    service_map = SERVICE_ID_V9 if (major != None and major >= 9) else SERVICE_ID_LOWER_V9

    col1 = _walk_col(ctx, host, community, ".1.3.6.1.4.1.7779.3.1.1.2.1.10.1.1")
    col2 = _walk_col(ctx, host, community, ".1.3.6.1.4.1.7779.3.1.1.2.1.10.1.2")
    col3 = _walk_col(ctx, host, community, ".1.3.6.1.4.1.7779.3.1.1.2.1.10.1.3")

    services = {}
    for idx in col1:
        service_id = col1[idx]
        service_name = service_map.get(service_id)
        if service_name == None:
            continue
        status_id = col2.get(idx, "5")
        status = STATUS_ID.get(status_id, "unexpected")
        if status == "inactive" or status == "unknown":
            continue
        desc = col3.get(idx, "")
        services[service_name] = (status, desc)

    return services

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        services = _get_services(ctx, host, community)
        items = sorted(services)
        discovery = [{"item": n, "params": {}, "metrics": []} for n in items]
        return {
            "changed": False,
            "msg": "discovered %d node services" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    services = _get_services(ctx, host, community)

    if item not in services:
        return {
            "changed": False,
            "msg": "node service not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status, desc = services[item]
    state = STATUS_STATE.get(status, "UNKNOWN")
    desc_part = (" (%s)" % desc) if desc else ""

    return {
        "changed": False,
        "msg": "Status: %s%s" % (status, desc_part),
        "data": {"state": state, "metrics": {}, "details": ""},
    }