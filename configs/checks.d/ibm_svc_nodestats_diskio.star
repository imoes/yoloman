# IBM SVC Storage Array - Disk IO / IOPS / Latency / CPU / Cache
#
# This check monitors IBM SAN Volume Controller (SVC) storage arrays.
# The data source is the SVC CLI, accessed via SSH to the SVC management
# interface. IBM SVC is a network-attached storage appliance; its statistics
# are NOT available from local /proc or /sys. If the SVC host is not
# reachable or credentials are missing, discovery returns an empty list and
# the check reports UNKNOWN.
#
# Original Checkmk checks: ibm_svc_nodestats_diskio, ibm_svc_nodestats_iops,
# ibm_svc_nodestats_disk_latency, ibm_svc_nodestats_cpu_util,
# ibm_svc_nodestats_cache

def _safe_float(s):
    """Convert string to float, returning 0.0 if not parseable."""
    s_str = s.strip()
    if s_str == "" or s_str == None:
        return 0.0
    # Handle negative numbers
    neg = False
    if s_str.startswith("-"):
        neg = True
        s_str = s_str[1:]
    if not s_str.isdigit() and not _is_decimal(s_str):
        return 0.0
    val = float(s_str) if "." in s_str else float(int(s_str))
    return -val if neg else val


def _is_decimal(s):
    """Check if string represents a decimal number."""
    parts = s.split(".")
    if len(parts) != 2:
        return False
    whole = parts[0]
    frac = parts[1]
    return _all_digits(whole) and _all_digits(frac)


def _all_digits(s):
    """Check if string contains only digits (or is empty)."""
    if s == "" or s == None:
        return True
    for ch in s:
        if not ch in "0123456789":
            return False
    return True


def _safe_int(s):
    """Convert string to int, returning 0 if not parseable."""
    s_str = s.strip()
    if s_str == "" or s_str == None:
        return 0
    if not s_str.isdigit():
        return 0
    return int(s_str)


def _format_iobandwidth(bytes_val):
    """Format byte value as a human-readable bandwidth string."""
    mb = bytes_val / (1024 * 1024)
    if mb >= 1024:
        return "%f GB/s" % (mb / 1024.0)
    elif mb >= 1:
        return "%f MB/s" % mb
    else:
        return "%f KB/s" % (mb * 1024.0)


def _parse_svc_output(raw):
    """Parse the output of svcinfo CLI commands for node stats.

    The SVC CLI returns data in a colon-separated format with a header row.
    Each data row belongs to a node identified by node_id.
    Returns a dict: { item_name: { stat_name: value } }
    """
    if raw == None or raw == "":
        return {}

    lines = raw.splitlines()
    if len(lines) == 0:
        return {}

    header = None
    parsed = {}
    for line in lines:
        fields = line.split(":")
        if len(fields) < 6:
            continue
        # Detect header row
        if fields[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
            header = fields
            continue
        if header == None:
            continue
        # Build dict from header
        row = dict(zip(header, fields))
        node_name = row.get("node_name", "")
        if node_name == "" or node_name == None:
            continue
        stat_name = row.get("stat_name", "")
        stat_current = row.get("stat_current", "0")

        value = _safe_float(stat_current)

        if stat_name in ("vdisk_r_mb", "vdisk_w_mb", "vdisk_r_io", "vdisk_w_io",
                         "vdisk_r_ms", "vdisk_w_ms"):
            item = "VDisks " + node_name
            short_name = stat_name.replace("vdisk_", "")
        elif stat_name in ("mdisk_r_mb", "mdisk_w_mb", "mdisk_r_io", "mdisk_w_io",
                           "mdisk_r_ms", "mdisk_w_ms"):
            item = "MDisks " + node_name
            short_name = stat_name.replace("mdisk_", "")
        elif stat_name in ("drive_r_mb", "drive_w_mb", "drive_r_io", "drive_w_io",
                           "drive_r_ms", "drive_w_ms"):
            item = "Drives " + node_name
            short_name = stat_name.replace("drive_", "")
        elif stat_name in ("write_cache_pc", "total_cache_pc", "cpu_pc"):
            item = node_name
            short_name = stat_name
        else:
            continue

        parsed.setdefault(item, {})[short_name] = value

    return parsed


def _gather_svc_data(ctx, params):
    """Gather node statistics from the IBM SVC array via SSH.

    Returns the parsed section dict, or None if the SVC is not reachable.
    """
    host = params.get("host")
    if host == None or host == "":
        return None

    username = params.get("username", "")
    password = params.get("password", "")

    # Build SSH command to run svcinfo on the SVC management interface
    svc_cmd = "svcinfo lsnodeinitstats -delim :"
    if username != "" or password != "":
        ssh_cmd = ["sshpass", "-p", password, "ssh", "-o", "StrictHostKeyChecking=no",
                   "-o", "ConnectTimeout=10", username + "@" + host, svc_cmd]
    else:
        ssh_cmd = ["ssh", "-o", "StrictHostKeyChecking=no",
                   "-o", "ConnectTimeout=10", host, svc_cmd]

    res = ctx.run(ssh_cmd, mutates=False)

    # rc != 0 means ssh failed, connection failed, or command not found
    if res.rc != 0:
        return None

    return _parse_svc_output(res.stdout)


def main(ctx, params):
    if params.get("_discover"):
        section = _gather_svc_data(ctx, params)
        if section == None:
            return {"changed": False, "msg": "no IBM SVC host reachable",
                    "data": {"discovery": []}}

        discovery = []
        for item_name, data in sorted(section.items()):
            check_metrics = []
            if "r_mb" in data and "w_mb" in data:
                check_metrics = check_metrics + ["read", "write"]
            if "r_io" in data and "w_io" in data:
                check_metrics = check_metrics + ["read", "write"]
            if "r_ms" in data and "w_ms" in data:
                check_metrics = check_metrics + ["read_latency", "write_latency"]
            if "cpu_pc" in data:
                check_metrics = check_metrics + ["cpu_util"]
            if "write_cache_pc" in data and "total_cache_pc" in data:
                check_metrics = check_metrics + ["write_cache_pc", "total_cache_pc"]

            discovery.append({
                "item": item_name,
                "params": {},
                "metrics": check_metrics,
            })

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE
    item = params.get("item", "")
    section = _gather_svc_data(ctx, params)

    if section == None:
        return {"changed": False,
                "msg": "IBM SVC host not reachable or not configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = section.get(item)
    if data == None:
        return {"changed": False,
                "msg": "no data for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Disk IO check: r_mb, w_mb
    if "r_mb" in data and "w_mb" in data:
        read_bytes = data["r_mb"] * 1024 * 1024
        write_bytes = data["w_mb"] * 1024 * 1024
        msg = "%s read, %s write" % (
            _format_iobandwidth(read_bytes), _format_iobandwidth(write_bytes))
        return {"changed": False, "msg": msg,
                "data": {"state": "OK",
                         "metrics": {"read": read_bytes, "write": write_bytes},
                         "details": ""}}

    # IOPS check: r_io, w_io
    if "r_io" in data and "w_io" in data:
        read_iops = data["r_io"]
        write_iops = data["w_io"]
        msg = "%d IO/s read, %d IO/s write" % (read_iops, write_iops)
        return {"changed": False, "msg": msg,
                "data": {"state": "OK",
                         "metrics": {"read": read_iops, "write": write_iops},
                         "details": ""}}

    # Disk latency check: r_ms, w_ms
    if "r_ms" in data and "w_ms" in data:
        read_latency = data["r_ms"]
        write_latency = data["w_ms"]
        msg = "Latency is %s ms for read, %s ms for write" % (
            str(read_latency), str(write_latency))
        return {"changed": False, "msg": msg,
                "data": {"state": "OK",
                         "metrics": {
                             "read_latency": read_latency,
                             "write_latency": write_latency},
                         "details": ""}}

    # Cache check: write_cache_pc, total_cache_pc
    if "write_cache_pc" in data and "total_cache_pc" in data:
        write_cache_pc = data["write_cache_pc"]
        total_cache_pc = data["total_cache_pc"]
        msg = "Write cache usage is %d %%, total cache usage is %d %%" % (
            _safe_int(str(int(write_cache_pc))), _safe_int(str(int(total_cache_pc))))
        return {"changed": False, "msg": msg,
                "data": {"state": "OK",
                         "metrics": {
                             "write_cache_pc": write_cache_pc,
                             "total_cache_pc": total_cache_pc},
                         "details": ""}}

    # CPU check: cpu_pc
    if "cpu_pc" in data:
        cpu_pc = data["cpu_pc"]
        levels = params.get("levels", (90.0, 95.0))
        warn = levels[0]
        crit = levels[1]
        state = "CRIT" if cpu_pc >= crit else ("WARN" if cpu_pc >= warn else "OK")
        msg = "CPU utilization: %s %%" % str(cpu_pc)
        return {"changed": False, "msg": msg,
                "data": {"state": state,
                         "metrics": {"cpu_util": cpu_pc},
                         "details": ""}}

    return {"changed": False, "msg": "no applicable metrics for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}