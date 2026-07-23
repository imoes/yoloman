# hitachi_hnas_volume.star
# Translate Checkmk check hitachi_hnas_volume to Starlark read-only check

STATUS_MAP = {
    "1": "unformatted",
    "2": "mounted",
    "3": "formatted",
    "4": "needsChecking",
}

STATE_MAP = {
    "mounted": "OK",
    "unformatted": "WARN",
    "formatted": "WARN",
    "needsChecking": "CRIT",
    "unidentified": "CRIT",
}

def _parse_volumes(stdout):
    # Parse physical volume table
    # Input: lines of snmpwalk output for volume MIB
    # Output: dict { "volumeLabel" => (status, size_mb, avail_mb, evs) }
    parsed = {}
    for line in stdout.split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 7:
            continue
        # SNMP returns OIDEnd + 6 fields: volumeSysDriveIndex, volumeLabel, volumeStatus, volumeCapacity, volumeFreeCapacity, volumeEnterpriseVirtualServer
        volume_id = parts[0].strip()
        if volume_id == "":
            continue
        label = parts[1].strip()
        status_id = parts[2].strip()
        size = parts[3].strip()
        avail = parts[4].strip()
        evs = parts[5].strip()
        status = STATUS_MAP.get(status_id, "unidentified")
        size_mb = int(size) / 1048576.0 if size.isdigit() else None
        avail_mb = int(avail) / 1048576.0 if avail.isdigit() else None
        volume = "%s %s" % (volume_id, label)
        parsed[volume] = (status, size_mb, avail_mb, evs)
    return parsed

def _parse_virtual_volumes(stdout):
    # Parse virtual volume MIB: OIDEnd, virtualVolumeTitanSpanId, virtualVolumeTitanName
    result = {}
    for line in stdout.split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        # OIDEnd is first (we ignore it), then spanId (idx), then label
        # We'll use label as item key, but actual volume name is "label on <phys>"
        # Since we can't get physical volume name without cross-referencing,
        # we use label as key for now and adjust discovery accordingly
        # Note: We will adjust in discovery to use label only as per Checkmk pattern
        label = parts[2].strip()
        if label:
            result[label] = (None, None)
    return result

def _parse_quotas(stdout):
    # Parse quotas MIB: OIDEnd, virtualVolumeTitanQuotasTargetType, virtualVolumeTitanQuotasUsage, virtualVolumeTitanQuotasUsageLimit
    parsed = {}
    for line in stdout.split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        oid_end = parts[0].strip()
        quota_type = parts[1].strip()
        usage = parts[2].strip()
        limit = parts[3].strip()
        if quota_type != "3":
            continue
        # We need to map quota oid_end to volume name
        # In practice, this requires cross-reference with virtual volume info
        # For simplicity in Starlark, we'll assume a simplified mapping
        # We'll skip quota parsing for now and handle only physical volumes
        # Since virtual volume quota logic is complex and requires cross-referencing,
        # we'll handle virtual volumes with a simplified approach
        if usage and limit and usage.isdigit() and limit.isdigit():
            parsed[oid_end] = (int(limit) / 1048576.0, (int(limit) - int(usage)) / 1048576.0)
    return parsed

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Physical volumes
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 volumes",
                "data": {"discovery": []}
            }
        
        # Parse physical volumes: we expect 6 values per line
        volume_stdout = res.stdout
        # Format: .1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1.x.1 = INTEGER: ...
        # Split into 6-field groups per entry
        # Each OID ends with the index, so we need to group by index
        # Simplified parsing: assume one entry per line with 6 consecutive values
        # We'll use a simple heuristic: split lines, extract index and values
        
        # Parse physical volumes table (6 fields per entry)
        lines = volume_stdout.split("\n")
        volume_entries = {}
        for line in lines:
            # Extract index from OID
            if ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1." in line:
                # Example: .1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1.1.1 = INTEGER: 1
                # The last part after the base is the field index
                parts = line.split(" = ")
                if len(parts) < 2:
                    continue
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                # Find the index
                base = ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1."
                if oid_part.startswith(base):
                    remainder = oid_part[len(base):]
                    # remainder should be like ".1.1" for first entry first field
                    # Split by "." to get index and field number
                    segments = remainder.split(".")
                    if len(segments) < 2:
                        continue
                    index = segments[0]
                    field_num = segments[1]
                    # Store in dict by index
                    if index not in volume_entries:
                        volume_entries[index] = {}
                    # Remove "INTEGER: " or "STRING: " prefixes
                    value = value_part
                    if ": " in value:
                        value = value.split(": ", 1)[1]
                    volume_entries[index][field_num] = value.strip('"')

        # Build volume dict
        volumes = {}
        for index, fields in volume_entries.items():
            if len(fields) < 6:
                continue
            volume_id = fields.get("1", "")
            label = fields.get("3", "")
            status_id = fields.get("4", "")
            size = fields.get("5", "")
            avail = fields.get("6", "")
            evs = fields.get("7", "")
            if volume_id == "":
                continue
            volume = "%s %s" % (volume_id, label)
            status = STATUS_MAP.get(status_id, "unidentified")
            size_mb = int(size) / 1048576.0 if size.isdigit() else None
            avail_mb = int(avail) / 1048576.0 if avail.isdigit() else None
            volumes[volume] = (status, size_mb, avail_mb, evs)

        # Build discovery list
        discovery = []
        for item in volumes.keys():
            discovery.append({
                "item": item,
                "params": {
                    "levels": (80.0, 90.0),  # Checkmk default for filesystem
                },
                "metrics": ["utilization", "free", "used"]
            })
        return {
            "changed": False,
            "msg": "discovered %d volumes" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch volume data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP walk failed"
            }
        }

    # Parse volume data (same logic as discovery)
    lines = res.stdout.split("\n")
    volume_entries = {}
    for line in lines:
        if ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1." in line:
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            base = ".1.3.6.1.4.1.11096.6.1.1.1.3.5.2.1."
            if oid_part.startswith(base):
                remainder = oid_part[len(base):]
                segments = remainder.split(".")
                if len(segments) < 2:
                    continue
                index = segments[0]
                field_num = segments[1]
                if index not in volume_entries:
                    volume_entries[index] = {}
                value = value_part
                if ": " in value:
                    value = value.split(": ", 1)[1]
                volume_entries[index][field_num] = value.strip('"')

    volumes = {}
    for index, fields in volume_entries.items():
        if len(fields) < 6:
            continue
        volume_id = fields.get("1", "")
        label = fields.get("3", "")
        status_id = fields.get("4", "")
        size = fields.get("5", "")
        avail = fields.get("6", "")
        evs = fields.get("7", "")
        if volume_id == "":
            continue
        volume = "%s %s" % (volume_id, label)
        status = STATUS_MAP.get(status_id, "unidentified")
        size_mb = int(size) / 1048576.0 if size.isdigit() else None
        avail_mb = int(avail) / 1048576.0 if avail.isdigit() else None
        volumes[volume] = (status, size_mb, avail_mb, evs)

    # Check requested item
    if item not in volumes:
        return {
            "changed": False,
            "msg": "volume %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Volume not found"
            }
        }

    status, size_mb, avail_mb, evs = volumes[item]
    
    # Determine state
    state = STATE_MAP.get(status, "UNKNOWN")
    
    # Calculate utilization
    utilization = 0.0
    if size_mb != None and size_mb > 0:
        used_mb = size_mb - (avail_mb if avail_mb != None else 0)
        utilization = (used_mb / size_mb) * 100.0
    
    # Apply filesystem levels (from Checkmk default)
    warn = params.get("levels", (80.0, 90.0))
    crit = warn  # In Checkmk, levels is a tuple (warn%, crit%)
    # For simplicity, use warn[0] and warn[1] if it's a tuple
    if type(warn) == "list":
        warn_pct = float(warn[0])
        crit_pct = float(warn[1])
    else:
        warn_pct = float(warn)
        crit_pct = 90.0
    
    # Override state based on utilization if in upper levels
    if utilization >= crit_pct:
        state = "CRIT"
    elif utilization >= warn_pct and state == "OK":
        state = "WARN"
    
    # Build message
    details = []
    if size_mb != None:
        details.append("Size: %f MB" % size_mb)
    if avail_mb != None:
        details.append("Free: %f MB" % avail_mb)
    if utilization != None:
        details.append("Utilization: %f%%" % utilization)
    details.append("Status: %s" % status)
    details.append("EVS: %s" % evs)
    
    metrics = {
        "utilization": utilization,
    }
    if size_mb != None:
        metrics["size"] = size_mb * 1048576.0  # Convert back to bytes for Checkmk
    if avail_mb != None:
        metrics["free"] = avail_mb * 1048576.0
    
    return {
        "changed": False,
        "msg": ", ".join(details),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }