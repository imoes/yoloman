def main(ctx, params):
    # Constants for SNMP OIDs
    BASE_OID = ".1.3.6.1.4.1.232.3.2.3.1.1"
    MAP_STATES = {
        "1": ("UNKNOWN", "other"),
        "2": ("OK", "OK"),
        "3": ("CRIT", "failed"),
        "4": ("WARN", "unconfigured"),
        "5": ("WARN", "recovering"),
        "6": ("WARN", "ready for rebuild"),
        "7": ("WARN", "rebuilding"),
        "8": ("CRIT", "wrong drive"),
        "9": ("CRIT", "bad connect"),
        "10": ("CRIT", "overheating"),
        "11": ("WARN", "shutdown"),
        "12": ("WARN", "automatic data expansion"),
        "13": ("CRIT", "not available"),
        "14": ("WARN", "queued for expansion"),
        "15": ("WARN", "multi-path access degraded"),
        "16": ("WARN", "erasing"),
    }
    
    def parse_snmp_output(output):
        entries = []
        lines = output.splitlines()
        for line in lines:
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip().lstrip(": ").strip('"')
            if not oid_part.startswith(BASE_OID):
                continue
            suffix = oid_part[len(BASE_OID):].lstrip(".")
            if "." not in suffix:
                continue
            parts2 = suffix.split(".", 1)
            if len(parts2) < 2:
                continue
            index_str = parts2[0]
            field_num = parts2[1]
            entries.append({
                "index": index_str,
                "field": field_num,
                "value": value_part
            })
        return entries
    
    def build_raid_entries(entries):
        by_index = {}
        for entry in entries:
            idx = entry["index"]
            field = entry["field"]
            value = entry["value"]
            if idx not in by_index:
                by_index[idx] = {"name": "", "status": "", "size": 0, "rebuild": 0}
            if field == "14":
                by_index[idx]["name"] = value
            elif field == "4":
                by_index[idx]["status"] = value
            elif field == "9":
                if value.isdigit():
                    by_index[idx]["size"] = int(value) * 1024 * 1024
            elif field == "12":
                if value.isdigit():
                    by_index[idx]["rebuild"] = int(value)
        return list(by_index.values())
    
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        entries = parse_snmp_output(res.stdout)
        raid_entries = build_raid_entries(entries)
        
        discovery = []
        for entry in raid_entries:
            name = entry["name"]
            if name == "":
                continue
            item_name = name.replace("\x00", r"\x00")
            discovery.append({
                "item": item_name,
                "params": {},
                "metrics": ["status", "size", "rebuild_percent"]
            })
        
        return {"changed": False, "msg": "discovered %d logical devices" % len(discovery),
                "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    entries = parse_snmp_output(res.stdout)
    raid_entries = build_raid_entries(entries)
    
    raid_entry = None
    for entry in raid_entries:
        name = entry["name"]
        if name == "":
            continue
        sanitized_name = name.replace("\x00", r"\x00")
        if sanitized_name == item:
            raid_entry = entry
            break
    
    if raid_entry == None:
        return {"changed": False, "msg": "device not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status = raid_entry.get("status", "")
    size = raid_entry.get("size", 0)
    rebuild_percent = raid_entry.get("rebuild", 0)
    
    state_info = MAP_STATES.get(status, ("UNKNOWN", "unknown"))
    state_str = state_info[0]
    status_readable = state_info[1]
    
    if state_str == "OK":
        state = "OK"
    elif state_str == "CRIT":
        state = "CRIT"
    elif state_str == "WARN":
        state = "WARN"
    else:
        state = "UNKNOWN"
    
    # Format size
    size_bytes = size
    if size_bytes < 1024:
        size_str = str(size_bytes) + " B"
    elif size_bytes < 1024 * 1024:
        size_str = str(size_bytes // 1024) + " KB"
    elif size_bytes < 1024 * 1024 * 1024:
        size_str = str(size_bytes // (1024 * 1024)) + " MB"
    else:
        size_str = str(size_bytes // (1024 * 1024 * 1024)) + " GB"
    
    msg = "Status: " + status_readable + ", Size: " + size_str
    details = ["Size: " + size_str]
    
    if status == "7" or status == "12":
        if rebuild_percent == 4294967295:
            msg += ", Rebuild: undetermined"
            details.append("Rebuild: undetermined")
        else:
            msg += ", Rebuild: " + str(rebuild_percent) + "%"
            details.append("Rebuild: " + str(rebuild_percent) + "%")
    
    metrics = {
        "status_code": int(status) if status.isdigit() else -1,
        "size_bytes": size_bytes,
        "rebuild_percent": rebuild_percent
    }
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": "; ".join(details)}}