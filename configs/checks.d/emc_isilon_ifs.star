MIBI = 1024 * 1024

def _parse_snmp_output(stdout):
    """Parse snmpwalk output to extract ifsTotalBytes and ifsAvailableBytes."""
    lines = stdout.splitlines() if stdout else []
    total = None
    avail = None
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Expected format: ".1.3.6.1.4.1.12124.1.3.1.0 = Counter64: 123456789"
        if ".1.3.6.1.4.1.12124.1.3.1.0" in stripped:
            parts = stripped.split("Counter64:")
            if len(parts) >= 2:
                val_str = parts[1].strip()
                if val_str.isdigit():
                    total = int(val_str)
        if ".1.3.6.1.4.1.12124.1.3.3.0" in stripped:
            parts = stripped.split("Counter64:")
            if len(parts) >= 2:
                val_str = parts[1].strip()
                if val_str.isdigit():
                    avail = int(val_str)
    return total, avail

def _df_check_filesystem_list(value_store, item, params, section_list):
    """Simplified df_check_filesystem_list logic for single filesystem."""
    # params defaults from FILESYSTEM_DEFAULT_PARAMS
    levels = params.get("levels", (80.0, 90.0))  # warn_percent, crit_percent
    if len(levels) < 2:
        levels = (levels[0], levels[0] * 1.125) if levels else (80.0, 90.0)
    warn_percent, crit_percent = levels[:2]

    # section_list is a list of FSBlock entries; we take the first one
    if not section_list:
        return {"state": "UNKNOWN", "msg": "No data available", "metrics": {}, "details": ""}

    # Parse section: (item_name, total_MiB, avail_MiB, reserved_MiB)
    section = section_list[0]
    if len(section) < 4:
        return {"state": "UNKNOWN", "msg": "Invalid data format", "metrics": {}, "details": ""}

    fs_item, total_MiB, avail_MiB, reserved_MiB = section
    total_bytes = total_MiB * MIBI
    avail_bytes = avail_MiB * MIBI
    used_bytes = total_bytes - avail_bytes

    if total_bytes == 0:
        return {"state": "UNKNOWN", "msg": "Total size is zero", "metrics": {}, "details": ""}

    used_percent = (used_bytes * 100.0) / total_bytes
    used_percent = float(used_percent)  # ensure float for thresholds

    # Determine state
    if used_percent >= crit_percent:
        state = "CRIT"
    elif used_percent >= warn_percent:
        state = "WARN"
    else:
        state = "OK"

    # Build message and metrics
    used_MiB = used_bytes // MIBI
    msg = "Cluster Size: %d MiB, Used: %d MiB (%f%%)" % (total_MiB, used_MiB, used_percent)
    metrics = {
        "size": total_bytes,
        "used": used_bytes,
        "used_percent": used_percent,
    }
    details = ""

    return {"state": state, "msg": msg, "metrics": metrics, "details": details}

def main(ctx, params):
    if params.get("_discover"):
        # SNMP walk for emc_isilon_ifs section
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.12124.1.3"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        total, avail = _parse_snmp_output(res.stdout)
        
        # For discovery, we only care if we have data; always discover "Cluster"
        discovery = []
        if total != None and avail != None:
            discovery.append({
                "item": "Cluster",
                "params": {"levels": (80.0, 90.0)},  # Checkmk default FILESYSTEM_DEFAULT_PARAMS
                "metrics": ["used_percent"]
            })
        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode for specific item
    item = params.get("item", "Cluster")
    if item != "Cluster":
        return {
            "changed": False,
            "msg": "No such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Gather data via SNMP
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.12124.1.3"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    total, avail = _parse_snmp_output(res.stdout)

    if total == None or avail == None:
        return {
            "changed": False,
            "msg": "No SNMP data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Build section (FSBlock): ("ifs", total_MiB, avail_MiB, 0)
    section = ("ifs", total // MIBI, avail // MIBI, 0)
    section_list = [section]

    # Apply check logic
    result = _df_check_filesystem_list(ctx, item, params, section_list)

    return {
        "changed": False,
        "msg": result["msg"],
        "data": {
            "state": result["state"],
            "metrics": result["metrics"],
            "details": result["details"]
        }
    }
