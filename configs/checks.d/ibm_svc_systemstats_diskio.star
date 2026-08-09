# IBM SVC systemstats disk IO throughput check (read-only)
# Translates checkmk.ibm_svc_systemstats_diskio
# Probes an IBM SVC storage array via SNMP for disk IO throughput stats.

MB = 1024 * 1024
IBM_ENTERPRISE = "1.3.6.1.4.1.2.3.1"

# IBM SVC system statistics OIDs (perf_counter table)
# Column for read MB, write MB, read IO, write IO, read ms, write ms
# These stats come from the IBM SVC performance MIB
STATS_BASE = "1.3.6.1.4.1.2.3.1.5.1"

# Disk stat column OIDs within the systemstats table
# VDisk stats
VDISK_R_MB_OID = STATS_BASE + ".1"
VDISK_W_MB_OID = STATS_BASE + ".2"
VDISK_R_IO_OID = STATS_BASE + ".3"
VDISK_W_IO_OID = STATS_BASE + ".4"
VDISK_R_MS_OID = STATS_BASE + ".5"
VDISK_W_MS_OID = STATS_BASE + ".6"

# MDisk stats
MDISK_R_MB_OID = STATS_BASE + ".7"
MDISK_W_MB_OID = STATS_BASE + ".8"
MDISK_R_IO_OID = STATS_BASE + ".9"
MDISK_W_IO_OID = STATS_BASE + ".10"
MDISK_R_MS_OID = STATS_BASE + ".11"
MDISK_W_MS_OID = STATS_BASE + ".12"

# Drive stats
DRIVE_R_MB_OID = STATS_BASE + ".13"
DRIVE_W_MB_OID = STATS_BASE + ".14"
DRIVE_R_IO_OID = STATS_BASE + ".15"
DRIVE_W_IO_OID = STATS_BASE + ".16"
DRIVE_R_MS_OID = STATS_BASE + ".17"
DRIVE_W_MS_OID = STATS_BASE + ".18"


def _render_bandwidth(bytes_val):
    """Render bytes as human-readable bandwidth string."""
    b = float(bytes_val)
    if b >= 1024 * 1024 * 1024:
        return "%f GB/s" % (b / (1024.0 * 1024.0 * 1024.0))
    elif b >= 1024 * 1024:
        return "%f MB/s" % (b / (1024.0 * 1024.0))
    elif b >= 1024:
        return "%f KB/s" % (b / 1024.0)
    return "%f B/s" % b


def _snmp_walk(ctx, community, host, oid):
    """Perform an SNMP walk and return list of (oid_suffix, value) tuples."""
    cmd = ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return []
    results = []
    for line in res.stdout.splitlines():
        # Line format: <full_oid> <value>
        idx = line.find(" ")
        if idx == -1:
            continue
        full_oid = line[:idx].strip()
        value = line[idx + 1:].strip()
        suffix = full_oid[len(oid):]
        if suffix.startswith("."):
            suffix = suffix[1:]
        results.append((suffix, value))
    return results


def _snmp_get(ctx, community, host, oid):
    """Perform an SNMP get and return the bare value string or None."""
    cmd = ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val == "" or val.startswith("No Response"):
        return None
    return val


def _gather_disk_stats(ctx, params):
    """Gather disk stats from IBM SVC via SNMP.
    Returns a dict: { item_name: { "r_mb": ..., "w_mb": ... } }
    """
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Probe for IBM SVC availability first via a known system OID
    sys_oid = _snmp_get(ctx, community, host, "1.3.6.1.2.1.1.1.0")
    if sys_oid == None:
        return {}

    disks = {}

    # Gather VDisk stats
    vdisk_r = _snmp_walk(ctx, community, host, VDISK_R_MB_OID)
    vdisk_w = _snmp_walk(ctx, community, host, VDISK_W_MB_OID)

    if len(vdisk_r) > 0 or len(vdisk_w) > 0:
        items = {}
        for suffix, val in vdisk_r:
            if val != None and val != "":
                items[suffix] = {"r_mb": float(val), "w_mb": 0.0}
        for suffix, val in vdisk_w:
            if val != None and val != "":
                if suffix not in items:
                    items[suffix] = {"r_mb": 0.0, "w_mb": float(val)}
                else:
                    items[suffix]["w_mb"] = float(val)
        if len(items) > 0:
            for idx in sorted(items.keys()):
                disks["VDisks_" + idx] = items[idx]

    # Gather MDisk stats
    mdisk_r = _snmp_walk(ctx, community, host, MDISK_R_MB_OID)
    mdisk_w = _snmp_walk(ctx, community, host, MDISK_W_MB_OID)

    if len(mdisk_r) > 0 or len(mdisk_w) > 0:
        items = {}
        for suffix, val in mdisk_r:
            if val != None and val != "":
                items[suffix] = {"r_mb": float(val), "w_mb": 0.0}
        for suffix, val in mdisk_w:
            if val != None and val != "":
                if suffix not in items:
                    items[suffix] = {"r_mb": 0.0, "w_mb": float(val)}
                else:
                    items[suffix]["w_mb"] = float(val)
        if len(items) > 0:
            for idx in sorted(items.keys()):
                disks["MDisks_" + idx] = items[idx]

    # Gather Drive stats
    drive_r = _snmp_walk(ctx, community, host, DRIVE_R_MB_OID)
    drive_w = _snmp_walk(ctx, community, host, DRIVE_W_MB_OID)

    if len(drive_r) > 0 or len(drive_w) > 0:
        items = {}
        for suffix, val in drive_r:
            if val != None and val != "":
                items[suffix] = {"r_mb": float(val), "w_mb": 0.0}
        for suffix, val in drive_w:
            if val != None and val != "":
                if suffix not in items:
                    items[suffix] = {"r_mb": 0.0, "w_mb": float(val)}
                else:
                    items[suffix]["w_mb"] = float(val)
        if len(items) > 0:
            for idx in sorted(items.keys()):
                disks["Drives_" + idx] = items[idx]

    return disks


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")

        # Probe for IBM SVC availability
        sys_oid = _snmp_get(ctx, community, host, "1.3.6.1.2.1.1.1.0")
        if sys_oid == None:
            return {"changed": False, "msg": "IBM SVC not reachable", "data": {"discovery": [], "host_labels": {}}}

        disks = _gather_disk_stats(ctx, params)
        discovery = []
        for item in sorted(disks.keys()):
            discovery.append({"item": item, "params": {}, "metrics": ["read", "write"]})

        labels = {"cmk/ibm_svc": "true"}
        return {"changed": False, "msg": "discovered %d disk IO items" % len(discovery), "data": {"discovery": discovery, "host_labels": labels}}

    item = params.get("item", "")
    disks = _gather_disk_stats(ctx, params)

    if item not in disks:
        return {"changed": False, "msg": "no such disk item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats = disks[item]
    read_bytes = stats["r_mb"] * float(MB)
    write_bytes = stats["w_mb"] * float(MB)

    summary = "%s read, %s write" % (_render_bandwidth(read_bytes), _render_bandwidth(write_bytes))

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {"read": int(read_bytes), "write": int(write_bytes)},
            "details": "",
        },
    }