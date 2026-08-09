# Translated Checkmk check: checkmk.cadvisor_df (Filesystem)
# READ-ONLY Starlark module for the yolo-man agent.

# Defaults mirror FILESYSTEM_DEFAULT_PARAMS from cmk.lib.df
# (warn_used: 80, crit_used: 90, warn_avail: 0, crit_avail: 0).
DEFAULT_WARN_USED = 80
DEFAULT_CRIT_USED = 90
DEFAULT_WARN_AVAIL = 0
DEFAULT_CRIT_AVAIL = 0


def _to_float(value):
    if value == None:
        return None
    if type(value) == "int" or type(value) == "float":
        return float(value)
    s = str(value)
    if s == "":
        return None
    # Starlark has no try/except; float() on non-numeric returns a non-fatal
    # error only if the string is malformed. Guard via format check.
    cleaned = s.strip()
    if cleaned == "":
        return None
    # Accept integers and floats; reject anything else.
    parts = cleaned.split(".")
    ok = True
    if len(parts) == 1:
        ok = parts[0].isdigit() or (parts[0].startswith("-") and parts[0][1:].isdigit())
    else:
        if len(parts) == 2:
            neg_left = parts[0].startswith("-")
            left = parts[0][1:] if neg_left else parts[0]
            right = parts[1]
            ok = (left.isdigit() or left == "") and right.isdigit()
        else:
            ok = False
    if not ok:
        return None
    return float(cleaned)


def _walk(node, item, found):
    fs_list = node.get("filesystem", [])
    for fs_entry in fs_list:
        if fs_entry.get("name", "") == item:
            found["df_size"] = fs_entry.get("size", 0)
            found["df_used"] = fs_entry.get("usage", 0)
            found["inodes_total"] = fs_entry.get("inodes_total", 0)
            found["inodes_free"] = fs_entry.get("inodes_free", 0)
            return True
    sub = node.get("subcontainers", [])
    for child in sub:
        if _walk(child, item, found):
            return True
    return False


def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        port = params.get("port", "8080")
        res = ctx.run(
            ["curl", "-fsS", "--max-time", "5", "http://%s:%s/api/v1.0/machine" % (host, port)],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "cAdvisor not reachable at %s:%s (rc %d)" % (host, port, res.rc),
                "data": {"discovery": []},
            }

        machine = json.decode(res.stdout)
        if not machine:
            return {
                "changed": False,
                "msg": "cAdvisor returned no machine info",
                "data": {"discovery": []},
            }

        filesystems = machine.get("filesystems", [])
        if len(filesystems) == 0:
            return {
                "changed": False,
                "msg": "cAdvisor reported no filesystems",
                "data": {"discovery": []},
            }

        items = []
        seen = set()
        for fs in filesystems:
            name = fs.get("name", "")
            if name == "" or name in seen:
                continue
            seen.add(name)
            items.append({
                "item": name,
                "params": {
                    "warn_used": DEFAULT_WARN_USED,
                    "crit_used": DEFAULT_CRIT_USED,
                    "warn_avail": DEFAULT_WARN_AVAIL,
                    "crit_avail": DEFAULT_CRIT_AVAIL,
                },
                "metrics": ["used_percent", "avail_mb"],
            })

        return {
            "changed": False,
            "msg": "discovered %d cAdvisor filesystem(s)" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    port = params.get("port", "8080")

    res = ctx.run(
        ["curl", "-fsS", "--max-time", "5", "http://%s:%s/api/v1.0/machine" % (host, port)],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "cAdvisor not reachable at %s:%s (rc %d)" % (host, port, res.rc),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    machine = json.decode(res.stdout)
    filesystems = machine.get("filesystems", [])
    target = None
    for fs in filesystems:
        if fs.get("name", "") == item:
            target = fs
            break

    if target == None:
        return {
            "changed": False,
            "msg": "no cAdvisor filesystem item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    stats_url = "http://%s:%s/api/v1.0/containers" % (host, port)
    sres = ctx.run(["curl", "-fsS", "--max-time", "10", stats_url], mutates=False)
    if sres.rc != 0 or not sres.stdout:
        return {
            "changed": False,
            "msg": "cAdvisor containers stats unreachable (rc %d)" % sres.rc,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    containers = json.decode(sres.stdout)
    found = {"df_size": None, "df_used": None, "inodes_total": None, "inodes_free": None}
    if not _walk(containers, item, found):
        return {
            "changed": False,
            "msg": "no cAdvisor filesystem stats for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    df_size = _to_float(found.get("df_size"))
    df_used = _to_float(found.get("df_used"))
    inodes_total = _to_float(found.get("inodes_total"))
    inodes_free = _to_float(found.get("inodes_free"))

    if df_size == None or df_used == None or inodes_total == None or inodes_free == None:
        return {
            "changed": False,
            "msg": "incomplete cAdvisor filesystem data for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    size_mb = df_size / (1024 * 1024)
    avail_mb = size_mb - (df_used / (1024 * 1024))
    used_percent = 0
    if size_mb > 0:
        used_percent = (100.0 * (size_mb - avail_mb) / size_mb)
    if used_percent != used_percent:
        used_percent = 0.0
    if used_percent > 100:
        used_percent = 100.0

    warn_used = params.get("warn_used", DEFAULT_WARN_USED)
    crit_used = params.get("crit_used", DEFAULT_CRIT_USED)

    state = "OK"
    if used_percent >= crit_used:
        state = "CRIT"
    elif used_percent >= warn_used:
        state = "WARN"

    details = "Size: %f MB, Used: %f MB (%f%%), Avail: %f MB" % (
        size_mb, df_used / (1024 * 1024), used_percent, avail_mb,
    )

    return {
        "changed": False,
        "msg": item + ": " + details,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "avail_mb": avail_mb,
            },
            "details": details,
        },
    }