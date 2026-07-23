# ===== Starlark check: fjdarye_ca_ports =====
# Translated from Checkmk check: checkmk.fjdarye_ca_ports

FJDARYE_SUPPORTED_DEVICES = [
    ".1.3.6.1.4.1.211.1.21.1.150",  # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153",  # fjdarye600
]

def _parse_snmp_output(string_table):
    map_modes = {
        "11": "CA",
        "12": "RA",
        "13": "CARA",
        "20": "Initiator",
    }
    parsed = {}
    for ports in string_table:
        for port_data in ports:
            if len(port_data) < 6:
                continue
            index, mode, read_iops, write_iops, read_mb, write_mb = port_data
            mode_readable = map_modes.get(mode, "Unknown")
            if index not in parsed:
                parsed[index] = {
                    "mode": mode_readable,
                    "read_ios": float(read_iops),
                    "read_throughput": float(read_mb) * 1024.0 * 1024.0,
                }
            if mode_readable != "Initiator":
                parsed[index]["write_ios"] = float(write_iops)
                parsed[index]["write_throughput"] = float(write_mb) * 1024.0 * 1024.0
    return parsed

def _walk_snmp(ctx, host, community, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    data = []
    for line in lines:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        # Remove OID prefix and get value part
        value_part = " ".join(parts[1:]).strip()
        # Handle type prefixes like "Integer32:", "Gauge32:", "Counter32:", etc.
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip()
        else:
            value = value_part
        # Extract OID index (last number in OID)
        oid = parts[0].strip()
        oid_parts = oid.split(".")
        if len(oid_parts) > 0:
            index = oid_parts[-1]
        else:
            index = ""
        data.append((index, value))
    return data

def _parse_snmp_table(ctx, host, community, base_oid, num_columns):
    # Walk base OID and organize by row index
    raw = _walk_snmp(ctx, host, community, base_oid)
    if raw == None:
        return None
    
    rows = {}
    for oid_idx, value in raw:
        # Determine column index from full OID
        full_oid = base_oid + "." + oid_idx
        # Get column index (position in the original SNMPTree)
        # We need to recompute based on original OIDs: 1,2,3,4,5,6
        # Simpler: group by index (oid_idx), then sort by full OID
        if oid_idx not in rows:
            rows[oid_idx] = {}
        
        # We need to know which OID position this value belongs to
        # We'll re-parse the full OID to get column position
        # Actually, snmpwalk output gives full OID with .index.column format
        # Parse full_oid to extract column number
        full_parts = full_oid.split(".")
        col = int(full_parts[-1]) if full_parts[-1].isdigit() else 0
        
        rows[oid_idx][col] = value
    
    # Convert rows into table rows
    table = []
    for idx in sorted(rows.keys(), key=lambda x: int(x) if x.isdigit() else 9999):
        row = []
        for col in range(1, num_columns + 1):
            if col in rows[idx]:
                row.append(rows[idx][col])
            else:
                row.append("")
        if len(row) == num_columns:
            table.append(row)
    return table

def _check_diskstat_dict_legacy(disk, params, value_store, this_time):
    # Simplified version of diskstat_dict_legacy logic
    # Only handle the core read/write throughput and IOPS metrics
    state = "OK"
    msg_parts = []
    
    metrics = {}
    
    read_ios = disk.get("read_ios", 0.0)
    write_ios = disk.get("write_ios", 0.0)
    read_tp = disk.get("read_throughput", 0.0)
    write_tp = disk.get("write_throughput", 0.0)
    
    # Threshold defaults (Checkmk diskstat check default parameters are empty, so we use no thresholds)
    # Read IOPS
    # For legacy diskstat, thresholds are applied per-device via levels parameter
    # Since params is empty by default in Checkmk, we skip thresholds
    metrics["read_ios"] = read_ios
    metrics["write_ios"] = write_ios
    metrics["read_throughput"] = read_tp
    metrics["write_throughput"] = write_tp
    
    return state, metrics

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        indices = params.get("indices", [])
        modes = params.get("modes", ["CA", "CARA"])
        
        section = {}
        for device_oid in FJDARYE_SUPPORTED_DEVICES:
            base = device_oid + ".5.5.2.1"
            table = _parse_snmp_table(ctx, host, community, base, 6)
            if table == None:
                continue
            parsed = _parse_snmp_output([table])
            for k, v in parsed.items():
                section[k] = v
        
        discovery = []
        for disk_index, attrs in section.items():
            if indices and disk_index not in indices:
                continue
            if modes and attrs["mode"] not in modes:
                continue
            metrics_list = ["read_ios", "write_ios", "read_throughput", "write_throughput"]
            # Filter write_ios/write_throughput for Initiator mode
            if attrs["mode"] == "Initiator":
                metrics_list = ["read_ios", "read_throughput"]
            discovery.append({
                "item": disk_index,
                "params": {},
                "metrics": metrics_list,
            })
        
        return {
            "changed": False,
            "msg": "discovered %d CA ports" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    section = {}
    for device_oid in FJDARYE_SUPPORTED_DEVICES:
        base = device_oid + ".5.5.2.1"
        table = _parse_snmp_table(ctx, host, community, base, 6)
        if table == None:
            continue
        parsed = _parse_snmp_output([table])
        for k, v in parsed.items():
            section[k] = v
    
    disk = section.get(item)
    if disk == None:
        return {
            "changed": False,
            "msg": "CA port not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state = "OK"
    msg_parts = []
    msg_parts.append("Mode: " + disk["mode"])
    
    # Build disk dict excluding mode and non-floats
    disk_filtered = {k: v for k, v in disk.items() if k != "mode" and type(v) == "float"}
    
    # Check with empty params (Checkmk default is {})
    state, metrics = _check_diskstat_dict_legacy(disk_filtered, {}, {}, 0.0)
    
    summary = ", ".join(msg_parts)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
