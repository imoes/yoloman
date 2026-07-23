def _parse_zfsget_agent(ctx, host_data):
    """Parse zfsget agent output (string_table) into a dict by mountpoint."""
    # Split zfs and df sections if [df] marker present
    zfs_lines = []
    df_lines = []
    in_df = False
    for line in host_data.splitlines():
        stripped = line.strip()
        if stripped == "[df]":
            in_df = True
            continue
        if in_df:
            df_lines.append(stripped)
        else:
            zfs_lines.append(stripped)
    
    # Parse ZFS properties
    zfs_data = {}
    for line in zfs_lines:
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        prop = " ".join(parts[1:-1]).strip()
        value = parts[-1]
        if prop == " quota " and value in ("0", "-"):
            continue
        if prop not in (" name ", " quota ", " used ", " available ", " mountpoint ", " type "):
            continue
        # Split prop and value
        idx = line.find(prop)
        if idx == -1:
            continue
        raw_value = line[idx + len(prop):].strip()
        # Convert value to MB with guard (no try/except)
        val = 0.0
        if raw_value == "-" or raw_value.replace(".", "").replace("-", "").isdigit():
            if raw_value == "-":
                val = 0.0
            else:
                # Guard: only convert if numeric
                val = float(raw_value) / (1024.0 * 1024.0) if raw_value.replace(".", "").replace("-", "").isdigit() else raw_value
        else:
            val = raw_value
        zfs_data.setdefault(name, {})[prop.strip()] = val

    # Map ZFS entries to mountpoints
    parsed_zfs = {}
    for entry in zfs_data.values():
        mp = str(entry.get("mountpoint", ""))
        if mp.startswith("/"):
            name = str(entry.get("name", ""))
            is_pool = "/" not in name
            if entry.get("type") == "filesystem":
                parsed_zfs[name] = entry

    # Parse df output
    parsed_df = {}
    for line in df_lines:
        if not line:
            continue
        parts = line.split()
        if len(parts) < 6:
            continue
        # Extract fields with guards
        mountpoint = parts[-1]
        if not mountpoint.startswith("/"):
            continue
        avail_str = parts[-3]
        used_str = parts[-4]
        kbytes_str = parts[-5]
        
        # Guard: check if all are digits before converting
        if avail_str.isdigit() and used_str.isdigit() and kbytes_str.isdigit():
            avail = int(avail_str)
            used = int(used_str)
            kbytes = int(kbytes_str)
            total = kbytes
            if used and avail and not total:
                total = used + avail
            else:
                avail = total - used
            # Convert to MB
            entry = {
                "name": "",
                "mountpoint": mountpoint,
                "total": total / 1024.0,
                "used": used / 1024.0,
                "available": avail / 1024.0,
            }
            # Find best matching ZFS device by name similarity (simplified)
            best_name = ""
            best_sim = 0.0
            for name in parsed_zfs:
                # Simple similarity: longest common prefix length / max length
                s1, s2 = name, mountpoint
                l = 0
                for i in range(min(len(s1), len(s2))):
                    if s1[i] == s2[i]:
                        l += 1
                    else:
                        break
                sim = float(l) / max(len(s1), len(s2)) if max(len(s1), len(s2)) > 0 else 0.0
                if sim > best_sim:
                    best_sim = sim
                    best_name = name
            if best_sim > 0.5:
                entry["name"] = best_name
            else:
                entry["name"] = mountpoint
            parsed_df[mountpoint] = entry

    # Merge df and zfs data by mountpoint
    merged = {}
    for mp, df_entry in parsed_df.items():
        zfs_entry = None
        if df_entry["name"]:
            zfs_entry = parsed_zfs.get(df_entry["name"])
        if not zfs_entry:
            for name, zentry in parsed_zfs.items():
                if zentry.get("mountpoint") == mp:
                    zfs_entry = zentry
                    break
        if zfs_entry:
            quota = zfs_entry.get("quota", None)
            used_val = zfs_entry.get("used", None)
            available = zfs_entry.get("available", None)
            if quota != None and quota == 0:
                quota = None
            if quota == None and used_val != None and available != None:
                total = float(used_val) + float(available)
            else:
                total = float(used_val) + float(available)
            merged[mp] = (mp, total, float(available), 0.0)
        else:
            total = df_entry["total"]
            avail = df_entry["available"]
            merged[mp] = (mp, total, avail, 0.0)

    return merged


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["zfs", "list", "-Hp", "-o", "name,quota,used,available,mountpoint,type"], mutates=False)
        zfs_list = res.stdout

        parsed = _parse_zfsget_agent(ctx, zfs_list)
        items = [mp for mp in parsed if mp not in ["/", "/dev", "/proc", "/sys", "/etc/mnttab", "/etc/svc/volatile", "/system/contract", "/system/object", "/dev/fd", "/tmp", "/var/run", "/lib/libc.so.1"]]
        discovery = []
        for mp in items:
            if mp in parsed:
                total = parsed[mp][1]
                discovery.append({
                    "item": mp,
                    "params": {"levels": (80.0, 90.0)},
                    "metrics": ["used_percent"],
                })
        return {
            "changed": False,
            "msg": "discovered %d ZFS filesystems" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    res = ctx.run(["zfs", "list", "-Hp", "-o", "name,quota,used,available,mountpoint,type", item], mutates=False)
    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "filesystem %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parsed = _parse_zfsget_agent(ctx, res.stdout)
    if item not in parsed:
        return {
            "changed": False,
            "msg": "filesystem %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mp, total, avail, _ = parsed[item]
    used = total - avail
    used_pct = (used / total * 100.0) if total > 0 else 0.0

    levels = params.get("levels", (80.0, 90.0))
    warn_pct, crit_pct = levels[0], levels[1]

    if used_pct >= crit_pct:
        state = "CRIT"
    elif used_pct >= warn_pct:
        state = "WARN"
    else:
        state = "OK"

    msg = "Size: %f MB, Used: %f MB (%f%%)" % (total, used, used_pct)
    metrics = {
        "size": total,
        "used": used,
        "used_percent": used_pct,
    }

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }