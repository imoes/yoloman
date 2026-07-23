# ===== Starlark module: checkmk.emc_datadomain_fs =====
# Copyright (C) 2019 Checkmk GmbH - License: GNU General Public License v2

# Excluded mountpoints (from cmk.plugins.lib.df.EXCLUDED_MOUNTPOINTS)
EXCLUDED_MOUNTPOINTS = [
    "/", "/proc", "/sys", "/dev", "/dev/shm", "/run", "/var/run", "/var/lock",
    "/boot", "/lib", "/lib64", "/bin", "/sbin", "/usr", "/usr/lib", "/usr/lib64",
    "/usr/bin", "/usr/sbin", "/usr/share", "/usr/local", "/usr/local/lib",
    "/usr/local/bin", "/opt", "/srv", "/home", "/root", "/tmp", "/var",
    "/var/log", "/var/tmp", "/var/cache", "/var/lib", "/var/spool", "/var/mail",
    "/var/www", "/var/lib/apt", "/var/lib/dpkg", "/var/lib/aptitude",
    "/var/lib/landscape", "/var/lib/ureadahead", "/var/lib/sudo",
]

DEFAULT_WARN = 80.0
DEFAULT_CRIT = 90.0
DEFAULT_INODE_WARN = 80.0
DEFAULT_INODE_CRIT = 90.0

def _parse_snmp_line(line):
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return None, None
    oid = parts[0].strip()
    value_part = parts[1].strip()
    colon_idx = value_part.find(": ")
    if colon_idx != -1:
        value = value_part[colon_idx + 2:].strip()
    else:
        value = value_part
    return oid, value

def _parse_oid_list(oid_to_value, base_oid):
    values = {}
    for oid, val in oid_to_value.items():
        if oid.startswith(base_oid):
            suffix = oid[len(base_oid):].strip(".")
            if suffix == "":
                values[""] = val
            else:
                idx = suffix.find(".")
                if idx == -1:
                    idx = len(suffix)
                key = int(suffix[:idx]) if suffix[:idx].isdigit() else suffix[:idx]
                values[key] = val
    return values

def _discover_fs(ctx, community, host):
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.19746.1.3.2.1.1"
    ], mutates=False)
    if res.rc != 0:
        return [], "SNMP error: " + res.stderr
    
    oid_to_value = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        oid, value = _parse_snmp_line(line)
        if oid and value:
            oid_to_value[oid] = value
    
    base = ".1.3.6.1.4.1.19746.1.3.2.1.1"
    col1 = _parse_oid_list(oid_to_value, base + ".1")
    col3 = _parse_oid_list(oid_to_value, base + ".3")
    col4 = _parse_oid_list(oid_to_value, base + ".4")
    col5 = _parse_oid_list(oid_to_value, base + ".5")
    col6 = _parse_oid_list(oid_to_value, base + ".6")
    col7 = _parse_oid_list(oid_to_value, base + ".7")
    col8 = _parse_oid_list(oid_to_value, base + ".8")
    
    items = []
    for idx in sorted(col1.keys()):
        mount = col8.get(idx)
        if mount == None:
            continue
        mount = str(mount).strip()
        if mount in EXCLUDED_MOUNTPOINTS:
            continue
        
        items.append({
            "item": mount,
            "params": {
                "levels": [DEFAULT_WARN, DEFAULT_CRIT],
                "levels_low": None,
                "levels_inode": [DEFAULT_INODE_WARN, DEFAULT_INODE_CRIT],
                "inodes_levels": [DEFAULT_INODE_WARN, DEFAULT_INODE_CRIT],
            },
            "metrics": ["used_percent", "size", "avail", "used"]
        })
    
    return items, None

def _check_fs(ctx, community, host, item, params):
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.19746.1.3.2.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr}
        }
    
    oid_to_value = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        oid, value = _parse_snmp_line(line)
        if oid and value:
            oid_to_value[oid] = value
    
    base = ".1.3.6.1.4.1.19746.1.3.2.1.1"
    col1 = _parse_oid_list(oid_to_value, base + ".1")
    col3 = _parse_oid_list(oid_to_value, base + ".3")
    col4 = _parse_oid_list(oid_to_value, base + ".4")
    col5 = _parse_oid_list(oid_to_value, base + ".5")
    col6 = _parse_oid_list(oid_to_value, base + ".6")
    col7 = _parse_oid_list(oid_to_value, base + ".7")
    col8 = _parse_oid_list(oid_to_value, base + ".8")
    
    found = False
    size_mb = 0.0
    avail_mb = 0.0
    
    for idx in col1.keys():
        mount = col8.get(idx)
        if mount == None:
            continue
        mount = str(mount).strip()
        if item == mount:
            total_str = col3.get(idx, "0")
            used_str = col4.get(idx, "0")
            avail_str = col5.get(idx, "0")
            
            # Guard against invalid numbers before conversion
            if total_str != None and str(total_str).strip().replace(".", "").replace("-", "").isdigit():
                total = float(str(total_str).strip())
                used = float(str(used_str).strip()) if used_str != None else 0.0
                avail = float(str(avail_str).strip()) if avail_str != None else 0.0
                size_mb = total * 1024.0
                avail_mb = avail * 1024.0
                found = True
            break
    
    if not found:
        return {
            "changed": False,
            "msg": "filesystem %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    used_mb = size_mb - avail_mb
    used_percent = (used_mb / size_mb * 100.0) if size_mb > 0 else 0.0
    
    levels = params.get("levels", [DEFAULT_WARN, DEFAULT_CRIT])
    warn = levels[0]
    crit = levels[1]
    
    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    
    msg = "%s %f%% used (%f MB / %f MB)" % (
        item, used_percent, used_mb, size_mb
    )
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "size": size_mb,
                "avail": avail_mb,
                "used": used_mb,
            },
            "details": ""
        },
    }

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    if params.get("_discover"):
        items, err = _discover_fs(ctx, community, host)
        if err != None:
            return {
                "changed": False,
                "msg": err,
                "data": {"discovery": []}
            }
        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(items),
            "data": {"discovery": items}
        }
    
    item = params.get("item", "")
    return _check_fs(ctx, community, host, item, params)
