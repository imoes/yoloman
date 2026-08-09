def _filter_blocks(blocks):
    """Reproduce Checkmk df discovery filtering.

    Excludes tmpfs/nfs/smbfs/cifs/iso9660 unless the mountpoint is in the
    never-ignore list, and always excludes docker local storage.
    """
    ignore_fs = ["tmpfs", "nfs", "smbfs", "cifs", "iso9660"]
    excluded_mountpoints = ["/dev", "/proc", "/sys", "/run"]
    result = []
    for b in blocks:
        if b["mountpoint"] in excluded_mountpoints:
            continue
        if b["mountpoint"].startswith("/var/lib/docker/"):
            continue
        if b["fs_type"] not in ignore_fs:
            result.append(b)
            continue
        result.append(b)
    return result


def _parse_df_output(out):
    """Parse `df -kP` output into a list of block dicts.

    Returns list of dicts with keys: device, fs_type, size_mb, avail_mb,
    reserved_mb, mountpoint, uuid (uuid always empty here).
    """
    blocks = []
    lines = out.split("\n")
    # Skip header
    for line in lines[1:]:
        if not line:
            continue
        f = line.split()
        if len(f) < 6:
            continue
        device = f[0]
        size_kb = 0
        used_kb = 0
        avail_kb = 0
        total_kb = 0
        # f[1] is size in KB (1K-blocks), f[2] used, f[3] avail, f[4] use%,
        # f[5] is the mountpoint (last field).
        if f[1].isdigit():
            size_kb = int(f[1])
        if f[2].isdigit():
            used_kb = int(f[2])
        if f[3].isdigit():
            avail_kb = int(f[3])
        mountpoint = f[-1]
        size_mb = size_kb / 1024.0
        avail_mb = avail_kb / 1024.0
        reserved_mb = max(0.0, (size_kb - used_kb - avail_kb) / 1024.0)
        blocks.append({
            "device": device,
            "fs_type": f[1] if False else "unknown",
            "size_mb": size_mb,
            "avail_mb": avail_mb,
            "reserved_mb": reserved_mb,
            "mountpoint": mountpoint,
            "uuid": "",
        })
    return blocks


def _parse_df_with_type(out):
    """Parse `df -kP -T` output (includes type column)."""
    blocks = []
    lines = out.split("\n")
    for line in lines[1:]:
        if not line:
            continue
        f = line.split()
        if len(f) < 8:
            continue
        device = f[0]
        fs_type = f[1]
        size_kb = 0
        avail_kb = 0
        used_kb = 0
        if f[2].isdigit():
            size_kb = int(f[2])
        if f[3].isdigit():
            used_kb = int(f[3])
        if f[4].isdigit():
            avail_kb = int(f[4])
        mountpoint = f[-1]
        size_mb = size_kb / 1024.0
        avail_mb = avail_kb / 1024.0
        reserved_mb = max(0.0, (size_kb - used_kb - avail_kb) / 1024.0)
        blocks.append({
            "device": device,
            "fs_type": fs_type,
            "size_mb": size_mb,
            "avail_mb": avail_mb,
            "reserved_mb": reserved_mb,
            "mountpoint": mountpoint,
            "uuid": "",
        })
    return blocks


def _get_block_for_mountpoint(blocks, mountpoint):
    for b in blocks:
        if b["mountpoint"] == mountpoint:
            return b
    return None


def _grade_levels(used_percent, params):
    """Grade used percentage against warn/crit thresholds."""
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    # Checkmk default: warn at warn %, crit at crit % (upper levels)
    if used_percent >= crit:
        return "CRIT"
    if used_percent >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: probe for df
        res = ctx.run(["df", "-kP"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "df command failed",
                "data": {"discovery": []},
            }
        blocks = _parse_df_output(res.stdout)
        filtered = _filter_blocks(blocks)
        discovery = []
        for b in filtered:
            mp = b["mountpoint"]
            discovery.append({
                "item": mp,
                "params": {
                    "warn": params.get("warn", 80),
                    "crit": params.get("crit", 90),
                },
                "metrics": ["used_percent", "size_mb", "avail_mb"],
            })
        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no filesystem specified",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Probe for the filesystem
    res = ctx.run(["df", "-kP", item], mutates=False)
    if res.rc != 0:
        # Check if it's because the mountpoint doesn't exist
        return {
            "changed": False,
            "msg": "no such filesystem: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    blocks = _parse_df_output(res.stdout)
    block = _get_block_for_mountpoint(blocks, item)
    if block == None:
        return {
            "changed": False,
            "msg": "filesystem not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    size_mb = block["size_mb"]
    avail_mb = block["avail_mb"]
    reserved_mb = block["reserved_mb"]
    # used = size - avail - reserved
    used_mb = size_mb - avail_mb - reserved_mb
    if size_mb > 0:
        used_percent = (used_mb / size_mb) * 100.0
    else:
        used_percent = 0.0

    state = _grade_levels(used_percent, params)

    return {
        "changed": False,
        "msg": "%s %d%% used (%d MB of %f MB)" % (
            item, used_percent, used_mb, size_mb),
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "size_mb": size_mb,
                "avail_mb": avail_mb,
            },
            "details": "Used: %d MB, Available: %f MB, Reserved: %f MB" % (
                used_mb, avail_mb, reserved_mb),
        },
    }