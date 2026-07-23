# Constants for service ID mapping (v9+ vs lower versions)
SERVICE_ID_lower_v9 = {
    "1": "dhcp", "2": "dns", "3": "ntp", "4": "tftp", "5": "http-file-dist",
    "6": "ftp", "7": "bloxtools-move", "8": "bloxtools", "9": "node-status",
    "10": "disk-usage", "11": "enet-lan", "12": "enet-lan2", "13": "enet-ha",
    "14": "enet-mgmt", "15": "lcd", "16": "memory", "17": "replication",
    "18": "db-object", "19": "raid-summary", "20": "raid-disk1", "21": "raid-disk2",
    "22": "raid-disk3", "23": "raid-disk4", "24": "raid-disk5", "25": "raid-disk6",
    "26": "raid-disk7", "27": "raid-disk8", "28": "fan1", "29": "fan2", "30": "fan3",
    "31": "fan4", "32": "fan5", "33": "fan6", "34": "fan7", "35": "fan8",
    "36": "power-supply1", "37": "power-supply2", "38": "ntp-sync", "39": "cpu1-temp",
    "40": "cpu2-temp", "41": "sys-temp", "42": "raid-battery", "43": "cpu-usage",
    "44": "ospf", "45": "bgp", "46": "mgm-service", "47": "subgrid-conn",
    "48": "network-capacity", "49": "reporting", "50": "dns-cache-acceleration",
    "51": "ospf6", "52": "swap-usage", "53": "discovery-consolidator",
    "54": "discovery-collector", "55": "discovery-capacity", "56": "threat-protection",
    "57": "cloud-api", "58": "threat-analytics", "59": "taxii", "60": "bfd",
    "61": "outbound"
}

SERVICE_ID_v9 = {
    "1": "dhcp", "2": "dns", "3": "ntp", "4": "tftp", "5": "http-file-dist",
    "6": "ftp", "7": "node-status", "8": "disk-usage", "9": "enet-lan",
    "10": "enet-lan2", "11": "enet-ha", "12": "enet-mgmt", "13": "memory",
    "14": "replication", "15": "db-object", "16": "raid-summary", "17": "raid-disk1",
    "18": "raid-disk2", "19": "raid-disk3", "20": "raid-disk4", "21": "raid-disk5",
    "22": "raid-disk6", "23": "raid-disk7", "24": "raid-disk8", "25": "fan1",
    "26": "fan2", "27": "fan3", "28": "fan4", "29": "fan5", "30": "fan6",
    "31": "fan7", "32": "fan8", "33": "power-supply1", "34": "power-supply2",
    "35": "ntp-sync", "36": "cpu1-temp", "37": "cpu2-temp", "38": "sys-temp",
    "39": "raid-battery", "40": "cpu-usage", "41": "ospf", "42": "bgp",
    "43": "mgm-service", "44": "subgrid-conn", "45": "network-capacity",
    "46": "reporting", "47": "dns-cache-acceleration", "48": "ospf6",
    "49": "swap-usage", "50": "discovery-consolidator", "51": "discovery-collector",
    "52": "discovery-capacity", "53": "threat-protection", "54": "cloud-api",
    "55": "threat-analytics", "56": "taxii", "57": "bfd", "58": "outbound"
}

STATUS_ID = {
    "1": "working", "2": "warning", "3": "failed", "4": "inactive", "5": "unknown"
}

STATE = {
    "working": "OK",
    "warning": "WARN",
    "failed": "CRIT",
    "unexpected": "UNKNOWN"
}

def _parse_version(version_str):
    if version_str == None or version_str == "":
        return None
    parts = version_str.split("-")[0].split(".")
    if len(parts) < 3:
        return None
    # Guard instead of try/except
    major = int(parts[0]) if parts[0].isdigit() else 0
    minor = int(parts[1]) if parts[1].isdigit() else 0
    patch = int(parts[2]) if parts[2].isdigit() else 0
    return {"major": major, "minor": minor, "patch": patch}

def _find_service_id_map(version):
    if version == None:
        return SERVICE_ID_lower_v9
    if version["major"] >= 9:
        return SERVICE_ID_v9
    return SERVICE_ID_lower_v9

def _parse_infoblox_services(string_table):
    if len(string_table) < 2:
        return {}
    raw_version = string_table[0]
    table = string_table[1]
    version_str = ""
    if len(raw_version) > 0 and len(raw_version[0]) > 0:
        version_str = raw_version[0][0]
    service_id_map = _find_service_id_map(_parse_version(version_str))
    result = {}
    for entry in table:
        if len(entry) < 3:
            continue
        service_id = entry[0]
        status_id = entry[1]
        description = entry[2]
        if service_id not in service_id_map:
            continue
        service_name = service_id_map[service_id]
        status = STATUS_ID.get(status_id, "unexpected")
        if status != "inactive" and status != "unknown":
            result[service_name] = (status, description)
    return result

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Get version (base: .1.3.6.1.4.1.7779.3.1.1.2.1, oid: 7)
        res_version = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.7779.3.1.1.2.1.7"
        ], mutates=False)
        version_output = res_version.stdout.strip()
        version = ""
        if version_output != "":
            for line in version_output.splitlines():
                if line.find(" = INTEGER:") != -1:
                    # Extract just the value part after "INTEGER:"
                    val_part = line.split(" = INTEGER:")[-1].strip()
                    version = val_part
                    break
        version_entry = [[version]] if version != "" else []

        # Get service table (base: .1.3.6.1.4.1.7779.3.1.1.2.1.9.1)
        # OIDs: 1=name, 2=status, 3=description
        res_services = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.7779.3.1.1.2.1.9.1"
        ], mutates=False)
        table_entries = []
        for line in res_services.stdout.splitlines():
            line = line.strip()
            if line == "":
                continue
            # Format: OID = STRING: "value" or OID = INTEGER: status or OID = STRING: "desc"
            # We need to group by instance
            # For simplicity, parse raw OID and value pairs
            # Split by " = " to get OID and value
            parts = line.split(" = ", 1)
            if len(parts) < 2:
                continue
            full_oid = parts[0].strip()
            value_raw = parts[1].strip()
            # Extract instance number from OID
            # e.g. .1.3.6.1.4.1.7779.3.1.1.2.1.9.1.1.1 -> last part is index
            base_oid = ".1.3.6.1.4.1.7779.3.1.1.2.1.9.1"
            if not full_oid.startswith(base_oid + "."):
                continue
            suffix = full_oid[len(base_oid)+1:]  # e.g. "1.1"
            dot_idx = suffix.find(".")
            if dot_idx == -1:
                continue
            index = suffix[:dot_idx]  # e.g. "1"
            # Determine OID suffix (1=name, 2=status, 3=desc)
            oid_num = suffix[dot_idx+1:]  # e.g. "1"
            # We'll parse all OIDs, group by index later
            # For now, collect all data
            table_entries.append({
                "oid_num": oid_num,
                "index": index,
                "value": value_raw
            })

        # Group by index
        services = {}
        for entry in table_entries:
            idx = entry["index"]
            if idx not in services:
                services[idx] = {"name": "", "status": "", "desc": ""}
            if entry["oid_num"] == "1":
                # Name: typically STRING: "value"
                val = entry["value"]
                if val.startswith('"'):
                    val = val[1:]
                if val.endswith('"'):
                    val = val[:-1]
                services[idx]["name"] = val
            elif entry["oid_num"] == "2":
                # Status: INTEGER: number
                val = entry["value"]
                if val.startswith("INTEGER: "):
                    val = val[len("INTEGER: "):]
                services[idx]["status"] = val.strip()
            elif entry["oid_num"] == "3":
                # Description: STRING: value
                val = entry["value"]
                if val.startswith('"'):
                    val = val[1:]
                if val.endswith('"'):
                    val = val[:-1]
                services[idx]["desc"] = val

        # Build table
        service_table = []
        for idx in services:
            svc = services[idx]
            if svc["name"] != "":
                service_table.append([svc["name"], svc["status"], svc["desc"]])

        # Parse using our function
        section = _parse_infoblox_services([version_entry, service_table])

        # Discover: one service per item
        discovery = []
        for item in section:
            discovery.append({
                "item": item,
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d services" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Get version
    res_version = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.7779.3.1.1.2.1.7"
    ], mutates=False)
    version_output = res_version.stdout.strip()
    version = ""
    if version_output != "":
        for line in version_output.splitlines():
            if line.find(" = INTEGER:") != -1:
                val_part = line.split(" = INTEGER:")[-1].strip()
                version = val_part
                break
    version_entry = [[version]] if version != "" else []

    # Get service table
    res_services = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.7779.3.1.1.2.1.9.1"
    ], mutates=False)

    table_entries = []
    for line in res_services.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0].strip()
        value_raw = parts[1].strip()
        base_oid = ".1.3.6.1.4.1.7779.3.1.1.2.1.9.1"
        if not full_oid.startswith(base_oid + "."):
            continue
        suffix = full_oid[len(base_oid)+1:]
        dot_idx = suffix.find(".")
        if dot_idx == -1:
            continue
        index = suffix[:dot_idx]
        oid_num = suffix[dot_idx+1:]
        table_entries.append({
            "oid_num": oid_num,
            "index": index,
            "value": value_raw
        })

    services = {}
    for entry in table_entries:
        idx = entry["index"]
        if idx not in services:
            services[idx] = {"name": "", "status": "", "desc": ""}
        if entry["oid_num"] == "1":
            val = entry["value"]
            if val.startswith('"'):
                val = val[1:]
            if val.endswith('"'):
                val = val[:-1]
            services[idx]["name"] = val
        elif entry["oid_num"] == "2":
            val = entry["value"]
            if val.startswith("INTEGER: "):
                val = val[len("INTEGER: "):]
            services[idx]["status"] = val.strip()
        elif entry["oid_num"] == "3":
            val = entry["value"]
            if val.startswith('"'):
                val = val[1:]
            if val.endswith('"'):
                val = val[:-1]
            services[idx]["desc"] = val

    service_table = []
    for idx in services:
        svc = services[idx]
        if svc["name"] != "":
            service_table.append([svc["name"], svc["status"], svc["desc"]])

    section = _parse_infoblox_services([version_entry, service_table])

    if item not in section:
        return {
            "changed": False,
            "msg": "Service not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status, description = section[item]
    summary = "Status: " + status
    if description != "":
        summary += " (%s)" % description
    state = STATE.get(status, "UNKNOWN")
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }