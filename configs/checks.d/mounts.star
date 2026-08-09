# Checkmk check: checkmk.mounts
# Translated to read-only Starlark for the yolo-man agent.
#
# Discovery reads /proc/self/mounts (the same source the Checkmk agent
# ``mounts`` plugin parses) and enumerates one Service per real mount point.
# The check mode path grades the live mount options against the expected
# options carried over from discovery parameters (defaulting to "[]").
#
# Read-only: every probe uses ``mutates=False``; ``changed`` is always False.

# Options that the Checkmk check explicitly ignores when diffing options.
# They are stable enough to treat as irrelevant rather than "exceeding".
_IGNORE_PREFIXES = [
    "commit=",
    "localalloc=",
    "subvol=",
    "subvolid=",
]


def _should_ignore_option(option):
    for prefix in _IGNORE_PREFIXES:
        if option.startswith(prefix):
            return True
    return False


def _read_mounts(ctx):
    # /proc/self/mounts is exactly what the Checkmk agent-based mounts
    # section reads. Each line: dev mountpoint fstype opts dump fsck.
    # Mountpoints use octal escapes (e.g. "\040" = space).
    res = ctx.run(["cat", "/proc/self/mounts"], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        parts = line.split()
        # A well-formed /proc/self/mounts line has 6 fields. Be lenient:
        # if we can't parse it, skip it rather than crash.
        if len(parts) < 4:
            continue
        dev = parts[0]
        mountpoint_raw = parts[1]
        fs_type = parts[2]
        options = parts[3]
        rows.append([dev, mountpoint_raw, fs_type, options])
    return rows


def _decode_mountpoint(mountpoint_raw):
    # Decode octal escapes like \040 (space), \011 (tab), \012 (newline).
    # Starlark has no regex; do a manual scan.
    out = ""
    i = 0
    n = len(mountpoint_raw)
    while i < n:
        ch = mountpoint_raw[i]
        if ch == "\\" and i + 3 <= n:
            oct3 = mountpoint_raw[i + 1:i + 4]
            if oct3.isdigit():
                out = out + chr(int(oct3, 8))
                i = i + 4
                continue
        out = out + ch
        i = i + 1
    return out


def _parse_mounts(ctx):
    rows = _read_mounts(ctx)
    devices = set()
    section = {}
    for dev, mountpoint_raw, fs_type, options in rows:
        if dev in devices:
            continue
        devices.add(dev)
        mountpoint = _decode_mountpoint(mountpoint_raw)
        mountname = mountpoint.replace("\\040(deleted)", "")
        # The deleted marker in /proc is literal "\040(deleted)" text on the
        # escaped mountpoint; detect via suffix on the decoded point.
        is_stale = mountpoint.endswith("\\040(deleted)")
        opts_sorted = sorted(options.split(","))
        section[mountname] = {
            "mountpoint": mountname,
            "options": opts_sorted,
            "fs_type": fs_type,
            "is_stale": is_stale,
        }
    return section


def main(ctx, params):
    if params.get("_discover"):
        section = _parse_mounts(ctx)
        discovery = []
        for m in section.values():
            if m["fs_type"] == "tmpfs":
                continue
            if m["mountpoint"] in ["/etc/resolv.conf", "/etc/hostname", "/etc/hosts"]:
                continue
            discovery.append({
                "item": m["mountpoint"],
                "params": {"expected_mount_options": m["options"]},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode for a single item.
    item = params.get("item", "")
    section = _parse_mounts(ctx)
    mount = section.get(item, None)
    if mount == None:
        return {
            "changed": False,
            "msg": "Mount point %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    if mount["is_stale"]:
        return {
            "changed": False,
            "msg": "Mount point detected as stale",
            "data": {
                "state": "WARN",
                "metrics": {},
                "details": "",
            },
        }

    targetopts = params.get("expected_mount_options", [])
    if targetopts == None:
        targetopts = []

    exceeding = [
        opt for opt in mount["options"]
        if opt not in targetopts and not _should_ignore_option(opt)
    ]
    missing = [
        opt for opt in targetopts
        if opt not in mount["options"] and not _should_ignore_option(opt)
    ]

    if not missing and not exceeding:
        return {
            "changed": False,
            "msg": "Mount options exactly as expected",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": "Mount options exactly as expected",
            },
        }

    summaries = []
    state = "OK"
    if missing:
        summaries.append("Missing: %s" % ",".join(missing))
        state = "WARN"
    if exceeding:
        summaries.append("Exceeding: %s" % ",".join(exceeding))
        state = "WARN"
    if "ro" in exceeding:
        summaries.append(
            "Filesystem has switched to read-only and is probably corrupted"
        )
        state = "CRIT"

    msg = "; ".join(summaries)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": msg,
        },
    }