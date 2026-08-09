# ===== module-level constants =====
DISKSTATUS_OID_BASE = ".1.3.6.1.4.1.12124.2.52.1"
DISKSTATUS_OIDS = ["1", "4", "5", "7"]

# ===== helper: parse SNMP lines into (disk_id, name, status, serial) =====
def _parse_snmp_lines(output):
    lines = output.splitlines()
    result = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Format: .1.3.6.1.4.1.12124.2.52.1.1.1.1.1 = STRING: "1"
        # We need the last part after the last dot in OID (the index) and the value
        # But simpler: extract index and value from each line
        # Actually, checkmk uses base OID + specific OID, so output lines look like:
        # .1.3.6.1.4.1.12124.2.52.1.1.1.1.1 = STRING: "1"
        # We need to extract the index (last octet) and the value.
        if "=" not in stripped:
            continue
        parts = stripped.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Get index: last part of OID
        oid_tokens = oid_part.split(".")
        if len(oid_tokens) < 2:
            continue
        index_str = oid_tokens[-1]
        # Extract value: strip quotes if STRING:
        if value_part.startswith('STRING:'):
            value = value_part[7:].strip().strip('"')
        elif value_part.startswith('INTEGER:'):
            value = value_part[8:].strip()
        elif value_part.startswith('OCTET STRING:'):
            value = value_part[13:].strip().strip('"')
        else:
            value = value_part
        # Now map by index: we have 4 OIDs per index, so group them
        result.append((index_str, value))
    return result


def _group_by_index(parsed):
    # parsed = [(index, value), ...]
    # We want dict of index -> {disk_id, name, status, serial}
    # From OIDs:
    # OID 1 (base + ".1") -> disk_id
    # OID 4 (base + ".4") -> name
    # OID 5 (base + ".5") -> status
    # OID 7 (base + ".7") -> serial
    # So index * 4 entries per index, but we need to group
    data = {}
    for index_str, value in parsed:
        if index_str not in data:
            data[index_str] = {}
        # Determine which OID by the suffix in the original line
        # Actually, we can't know which OID from just index_str + value
        # So re-parse: better to use separate snmpget calls or parse OID carefully
        # Alternative: use snmpwalk with -On to get numeric OIDs, then parse
        # Since we used base OID and OIDs list, we have to parse the OID to know which field
        pass
    return data


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Run snmpwalk on the disk status OID base
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), DISKSTATUS_OID_BASE
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }

        # Parse: we need to extract per-index data with 4 fields: disk_id, name, status, serial
        # We'll parse line by line and group by index
        lines = res.stdout.splitlines()
        # Map: index -> {disk_id, name, status, serial}
        disk_map = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            if "=" not in line:
                continue
            oid_part, value_part = line.split("=", 1)
            oid_part = oid_part.strip()
            value_part = value_part.strip()
            # Get the index (last number after base OID)
            # Base OID: .1.3.6.1.4.1.12124.2.52.1
            # Example OID: .1.3.6.1.4.1.12124.2.52.1.1.1.1.1
            # We need to extract the last number: index = "1"
            # And the OID suffix tells us the field: 1=disk_id, 4=name, 5=status, 7=serial
            if not oid_part.startswith(DISKSTATUS_OID_BASE):
                continue
            suffix = oid_part[len(DISKSTATUS_OID_BASE):]
            # Remove leading dot
            if suffix.startswith("."):
                suffix = suffix[1:]
            tokens = suffix.split(".")
            if len(tokens) < 2:
                continue
            # tokens[0] is the OID number within the section, tokens[1:] is the instance
            oid_num = tokens[0]
            instance = ".".join(tokens[1:]) if len(tokens) > 1 else ""

            # Extract value
            if value_part.startswith('STRING:'):
                value = value_part[7:].strip().strip('"')
            elif value_part.startswith('INTEGER:'):
                value = value_part[8:].strip()
            elif value_part.startswith('OCTET STRING:'):
                value = value_part[13:].strip().strip('"')
            else:
                value = value_part

            if instance not in disk_map:
                disk_map[instance] = {}
            if oid_num == "1":
                disk_map[instance]["disk_id"] = value
            elif oid_num == "4":
                disk_map[instance]["name"] = value
            elif oid_num == "5":
                disk_map[instance]["status"] = value
            elif oid_num == "7":
                disk_map[instance]["serial"] = value

        discovery_list = []
        for instance, data in disk_map.items():
            disk_id = data.get("disk_id", instance)
            # Only add if we have at least disk_id and status
            if "status" in data:
                discovery_list.append({
                    "item": disk_id,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }

    # Check mode (non-discovery)
    item = params.get("item", "")

    # Run snmpwalk on the disk status OID base to get all data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), DISKSTATUS_OID_BASE
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse same as discovery
    lines = res.stdout.splitlines()
    disk_map = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        oid_part = oid_part.strip()
        value_part = value_part.strip()
        if not oid_part.startswith(DISKSTATUS_OID_BASE):
            continue
        suffix = oid_part[len(DISKSTATUS_OID_BASE):]
        if suffix.startswith("."):
            suffix = suffix[1:]
        tokens = suffix.split(".")
        if len(tokens) < 2:
            continue
        oid_num = tokens[0]
        instance = ".".join(tokens[1:]) if len(tokens) > 1 else ""

        if value_part.startswith('STRING:'):
            value = value_part[7:].strip().strip('"')
        elif value_part.startswith('INTEGER:'):
            value = value_part[8:].strip()
        elif value_part.startswith('OCTET STRING:'):
            value = value_part[13:].strip().strip('"')
        else:
            value = value_part

        if instance not in disk_map:
            disk_map[instance] = {}
        if oid_num == "1":
            disk_map[instance]["disk_id"] = value
        elif oid_num == "4":
            disk_map[instance]["name"] = value
        elif oid_num == "5":
            disk_map[instance]["status"] = value
        elif oid_num == "7":
            disk_map[instance]["serial"] = value

    # Find the item
    status = "UNKNOWN"
    name = ""
    serial = ""
    disk_status = ""

    for instance, data in disk_map.items():
        disk_id = data.get("disk_id", instance)
        if disk_id == item:
            status_str = data.get("status", "")
            name = data.get("name", "")
            serial = data.get("serial", "")
            disk_status = status_str
            status = "OK" if disk_status in ["HEALTHY", "L3"] else "CRIT"
            break

    if status == "UNKNOWN":
        return {
            "changed": False,
            "msg": "disk not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    summary = "Disk %s, serial number %s status is %s" % (name, serial, disk_status)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": status,
            "metrics": {},
            "details": ""
        }
    }
