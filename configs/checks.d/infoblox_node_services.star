# Infoblox node services - read-only Starlark check (SNMP). No try/except.

SERVICE_ID_lower_v9 = {
    "1": "dhcp",
    "2": "dns",
    "3": "ntp",
    "4": "tftp",
    "5": "http-file-dist",
    "6": "ftp",
    "7": "bloxtools-move",
    "8": "bloxtools",
    "9": "node-status",
    "10": "disk-usage",
    "11": "enet-lan",
    "12": "enet-lan2",
    "13": "enet-ha",
    "14": "enet-mgmt",
    "15": "lcd",
    "16": "memory",
    "17": "replication",
    "18": "db-object",
    "19": "raid-summary",
    "20": "raid-disk1",
    "21": "raid-disk2",
    "22": "raid-disk3",
    "23": "raid-disk4",
    "24": "raid-disk5",
    "25": "raid-disk6",
    "26": "raid-disk7",
    "27": "raid-disk8",
    "28": "fan1",
    "29": "fan2",
    "30": "fan3",
    "31": "fan4",
    "32": "fan5",
    "33": "fan6",
    "34": "fan7",
    "35": "fan8",
    "36": "power-supply1",
    "37": "power-supply2",
    "38": "ntp-sync",
    "39": "cpu1-temp",
    "40": "cpu2-temp",
    "41": "sys-temp",
    "42": "raid-battery",
    "43": "cpu-usage",
    "44": "ospf",
    "45": "bgp",
    "46": "mgm-service",
    "47": "subgrid-conn",
    "48": "network-capacity",
    "49": "reporting",
    "50": "dns-cache-acceleration",
    "51": "ospf6",
    "52": "swap-usage",
    "53": "discovery-consolidator",
    "54": "discovery-collector",
    "55": "discovery-capacity",
    "56": "threat-protection",
    "57": "cloud-api",
    "58": "threat-analytics",
    "59": "taxii",
    "60": "bfd",
    "61": "outbound",
}
SERVICE_ID_v9 = {
    "1": "dhcp",
    "2": "dns",
    "3": "ntp",
    "4": "tftp",
    "5": "http-file-dist",
    "6": "ftp",
    "7": "node-status",
    "8": "disk-usage",
    "9": "enet-lan",
    "10": "enet-lan2",
    "11": "enet-ha",
    "12": "enet-mgmt",
    "13": "memory",
    "14": "replication",
    "15": "db-object",
    "16": "raid-summary",
    "17": "raid-disk1",
    "18": "raid-disk2",
    "19": "raid-disk3",
    "20": "raid-disk4",
    "21": "raid-disk5",
    "22": "raid-disk6",
    "23": "raid-disk7",
    "24": "raid-disk8",
    "25": "fan1",
    "26": "fan2",
    "27": "fan3",
    "28": "fan4",
    "29": "fan5",
    "30": "fan6",
    "31": "fan7",
    "32": "fan8",
    "33": "power-supply1",
    "34": "power-supply2",
    "35": "ntp-sync",
    "36": "cpu1-temp",
    "37": "cpu2-temp",
    "38": "sys-temp",
    "39": "raid-battery",
    "40": "cpu-usage",
    "41": "ospf",
    "42": "bgp",
    "43": "mgm-service",
    "44": "subgrid-conn",
    "45": "network-capacity",
    "46": "reporting",
    "47": "dns-cache-acceleration",
    "48": "ospf6",
    "49": "swap-usage",
    "50": "discovery-consolidator",
    "51": "discovery-collector",
    "52": "discovery-capacity",
    "53": "threat-protection",
    "54": "cloud-api",
    "55": "threat-analytics",
    "56": "taxii",
    "57": "bfd",
    "58": "outbound",
}
STATUS_ID = {
    "1": "working",
    "2": "warning",
    "3": "failed",
    "4": "inactive",
    "5": "unknown",
}
STATE = {
    "working": "OK",
    "warning": "WARN",
    "failed": "CRIT",
    "unexpected": "UNKNOWN",
}
VERSION_OID = ".1.3.6.1.4.1.7779.3.1.1.2.1.7"
NODE_SERVICE_BASE = ".1.3.6.1.4.1.7779.3.1.1.2.1.10.1"

def _int_or_zero(s):
    if s == None or s == "":
        return 0
    if s.isdigit():
        return int(s)
    return 0

def _parse_version(version_str):
    if version_str == None or version_str == "":
        return None
    parts = version_str.split("-")[0].split(".")
    if len(parts) < 3:
        return None
    major = _int_or_zero(parts[0])
    minor = _int_or_zero(parts[1])
    patch = _int_or_zero(parts[2])
    return (major, minor, patch)

def _find_service_id_map(version_str):
    v = _parse_version(version_str)
    if v == None or v[0] < 9:
        return SERVICE_ID_lower_v9
    return SERVICE_ID_v9

def _fetch_version(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, VERSION_OID], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _strip_string(text):
    s = text
    if s.startswith("STRING:"):
        s = s[len("STRING:"):]
    s = s.lstrip()
    if len(s) > 0 and s[0] == '"':
        s = s[1:]
    if len(s) > 0 and s[-1] == '"':
        s = s[:-1]
    return s

def _probe_infoblox(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Ov", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False
    sysoid = res.stdout.strip()
    if sysoid.startswith(".1.3.6.1.4.1.7779.1."):
        return True
    res2 = ctx.run(["snmpget", "-v2c", "-c", community, "-Ov", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if res2.rc != 0:
        return False
    desc = _strip_string(res2.stdout)
    return "infoblox" in desc.lower()

def _walk_column(ctx, host, community, col_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid], mutates=False)
    out = {}
    if res.rc != 0:
        return out
    for line in res.stdout.splitlines():
        space = line.find(" ")
        if space < 0:
            continue
        line_oid = line[:space]
        value = line[space + 1:]
        prefix = col_oid + "."
        if line_oid.startswith(prefix):
            idx = line_oid[len(prefix):]
            out[idx] = value
    return out

def _walk_node_services(ctx, host, community):
    names = _walk_column(ctx, host, community, NODE_SERVICE_BASE + ".1")
    statuses = _walk_column(ctx, host, community, NODE_SERVICE_BASE + ".2")
    descs = _walk_column(ctx, host, community, NODE_SERVICE_BASE + ".3")
    result = []
    for idx in names:
        result.append((names[idx], statuses.get(idx, "5"), descs.get(idx, "")))
    return result

def _parse_services(version_str, table_rows):
    service_id_map = _find_service_id_map(version_str)
    out = {}
    for service_id, status_id, description in table_rows:
        status = STATUS_ID.get(status_id, "unexpected")
        if status in ("inactive", "unknown"):
            continue
        name = service_id_map.get(service_id)
        if name == None:
            continue
        out[name] = (status, description)
    return out

def _gather_section(ctx, host, community):
    version_str = _fetch_version(ctx, host, community)
    table = _walk_node_services(ctx, host, community)
    return _parse_services(version_str, table)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _probe_infoblox(ctx, host, community):
            return {"changed": False, "msg": "not an Infoblox device", "data": {"discovery": [], "host_labels": {}}}
        section = _gather_section(ctx, host, community)
        discovery = []
        for item in section:
            discovery.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d node services" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    if not _probe_infoblox(ctx, host, community):
        return {"changed": False, "msg": "not an Infoblox device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _gather_section(ctx, host, community)
    if item not in section:
        return {"changed": False, "msg": "service not found: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status, description = section[item]
    summary = "Status: %s" % status
    if description:
        summary = summary + " (" + description + ")"
    st = STATE.get(status, "UNKNOWN")
    return {"changed": False, "msg": summary, "data": {"state": st, "metrics": {}, "details": ""}}