# Translated from Checkmk's ucd_disk check plugin (UCD-SNMP-MIB disk check).
# Reads the same UCD-MIB disk table via SNMP and reproduces df_check_filesystem_single
# threshold logic for filesystems advertised by the on-device dskTable.

# Default filesystem level parameters (mirrors FILESYSTEM_DEFAULT_PARAMS used by df).
_FILESYSTEM_DEFAULT_PARAMS = {
    "warn": 80,
    "crit": 90,
    "levels": (80, 90),
    "growth": (0, 0),
    "growth_levels": None,
    "inodes": None,
    "inodes_space": None,
    "reservation": 0,
    "ignore": False,
}

# UCD-MIB dskTable base OID — .1.3.6.1.4.1.2021.9.1
_UCD_DISK_BASE = ".1.3.6.1.4.1.2021.9.1"
# Columns in the dskTable:
#   2 -> dskPath (string)
#   6 -> dskTotal (kb)
#   7 -> dskAvail (kb)
_UCD_COLS = {
    "path": "2",
    "total": "6",
    "avail": "7",
}


def _snmp_get(ctx, oid, community, host):
    res = ctx.run(
        [
            "snmpget", "-v2c",
            "-c", community,
            "-Oqv",
            host,
            oid,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk(ctx, oid, community, host):
    res = ctx.run(
        [
            "snmpwalk", "-v2c",
            "-c", community,
            "-Oqn",
            host,
            oid,
        ],
        mutates=False,
    )
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        space = line.find(" ")
        if space == -1:
            continue
        oid_part = line[:space]
        val_part = line[space + 1:]
        out.append((oid_part, val_part))
    return out


def _is_number(s):
    if s == None:
        return False
    t = type(s)
    if t != "string":
        return False
    s = s.strip()
    if s == "":
        return False
    # Handle optional leading sign and a single decimal point.
    dot_seen = False
    digits = False
    start = 0
    if s[0] == "-" or s[0] == "+":
        start = 1
    for i in range(start, len(s)):
        c = s[i]
        if c >= "0" and c <= "9":
            digits = True
        elif c == "." and not dot_seen:
            dot_seen = True
        else:
            return False
    return digits


def _gather_disks(ctx, params):
    """Return list of (path, total_kb, avail_kb) tuples from the UCD dskTable."""
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Walk dskPath (col 2) to discover indexed filesystems.
    path_walk = _snmp_walk(ctx, _UCD_DISK_BASE + "." + _UCD_COLS["path"], community, host)
    if len(path_walk) == 0:
        return []

    col_base_len = len(_UCD_DISK_BASE) + 1  # +1 for the leading dot before column digit
    disks = []
    for oid_path, path_val in path_walk:
        # Compute the table index: suffix of the OID after "<base>.<col>."
        # oid_path looks like ".1.3.6.1.4.1.2021.9.1.2.<index>"
        prefix = _UCD_DISK_BASE + "." + _UCD_COLS["path"] + "."
        if not oid_path.startswith(prefix):
            continue
        idx = oid_path[len(prefix):]
        if idx == "" or "." in idx:
            # Index should be a plain integer suffix.
            continue

        # Read total (col 6) and avail (col 7) by numeric index.
        total_oid = _UCD_DISK_BASE + "." + _UCD_COLS["total"] + "." + idx
        avail_oid = _UCD_DISK_BASE + "." + _UCD_COLS["avail"] + "." + idx

        total_val = _snmp_get(ctx, total_oid, community, host)
        avail_val = _snmp_get(ctx, avail_oid, community, host)
        if total_val == None or avail_val == None:
            continue
        disks.append((path_val, total_val, avail_val))

    return disks


def _df_level(value, warn, crit, direction):
    """Grade a percentage-based value. direction='upper' or 'lower'."""
    if direction == "upper":
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
        return "OK"
    if value <= warn:
        return "WARN"
    if value <= crit:
        return "CRIT"
    return "OK"


def _df_check_filesystem_single(path, size_mb, avail_mb, params):
    """Reproduce the core logic of df_check_filesystem_single:
    compute used % = (total - avail) / total * 100 and apply warn/crit.
    Returns (state, used_pct, avail_pct, msg)."""
    warn = params.get("warn", _FILESYSTEM_DEFAULT_PARAMS.get("warn"))
    crit = params.get("crit", _FILESYSTEM_DEFAULT_PARAMS.get("crit"))
    levels = params.get("levels", _FILESYSTEM_DEFAULT_PARAMS.get("levels"))

    if levels != None and type(levels) == "list" and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]

    if size_mb == None or size_mb <= 0:
        return ("UNKNOWN", None, None, "no size information for " + str(path))

    used_mb = size_mb - avail_mb
    if used_mb < 0:
        used_mb = 0
    used_pct = (used_mb / size_mb) * 100.0
    avail_pct = 100.0 - used_pct

    state = _df_level(used_pct, warn, crit, "upper")
    msg = (
        "size: %f MB, used: %f MB (%f%%), avail: %f MB (%f%%)"
        % (size_mb, used_mb, used_pct, avail_mb, avail_pct)
    )
    return (state, used_pct, avail_pct, msg)


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        disks = _gather_disks(ctx, params)
        discovery = []
        for path, total_kb, avail_kb in disks:
            item = path
            entry_params = {
                "warn": params.get("warn", _FILESYSTEM_DEFAULT_PARAMS.get("warn")),
                "crit": params.get("crit", _FILESYSTEM_DEFAULT_PARAMS.get("crit")),
            }
            discovery.append({
                "item": item,
                "params": entry_params,
                "metrics": ["used_percent"],
                "service_labels": {"cmk/filesystem_type": ""},
            })
        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(disks),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    disks = _gather_disks(ctx, params)
    if len(disks) == 0:
        return {
            "changed": False,
            "msg": "no UCD disk entry found on %s" % host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    found = None
    for path, total_kb, avail_kb in disks:
        if path == item:
            found = (total_kb, avail_kb)
            break

    if found == None:
        return {
            "changed": False,
            "msg": "filesystem %s not found on %s" % (item, host),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total_kb, avail_kb = found

    if not (_is_number(total_kb) and _is_number(avail_kb)):
        return {
            "changed": False,
            "msg": "invalid size data for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    size_mb = float(total_kb) / 1024.0
    avail_mb = float(avail_kb) / 1024.0

    state, used_pct, avail_pct, msg = _df_check_filesystem_single(item, size_mb, avail_mb, params)

    metrics = {}
    if used_pct != None:
        metrics["used_percent"] = used_pct
    if avail_pct != None:
        metrics["avail_percent"] = avail_pct

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }