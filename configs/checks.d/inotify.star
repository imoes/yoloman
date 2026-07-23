DEFAULT_CFG = "/etc/check_mk/inotify.cfg"

def _parse_config(content):
    items = []
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        if parts[0] in ("file", "folder"):
            items.append((parts[1], parts[0]))
        elif parts[1] in ("file", "folder"):
            items.append((parts[0], parts[1]))
    return items

def _fmt_duration(sec):
    sec = int(sec)
    if sec < 0:
        sec = 0
    if sec < 60:
        return "%d s" % sec
    if sec < 3600:
        return "%d min %d s" % (sec // 60, sec % 60)
    if sec < 86400:
        return "%d h %d min" % (sec // 3600, (sec % 3600) // 60)
    return "%d d %d h" % (sec // 86400, (sec % 86400) // 3600)

def main(ctx, params):
    cfg_path = params.get("config_file", DEFAULT_CFG)

    if params.get("_discover"):
        if not ctx.file_exists(cfg_path):
            return {"changed": False, "msg": "config not found", "data": {"discovery": []}}
        configured = _parse_config(ctx.file_read(cfg_path))
        discovery = [
            {
                "item": kind.title() + " " + path,
                "params": {"age_last_operation": []},
                "metrics": ["age_modify"],
            }
            for path, kind in configured
        ]
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    parts = item.split(" ", 1)
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    kind = parts[0].lower()
    path = parts[1]

    if not ctx.file_exists(cfg_path):
        return {
            "changed": False,
            "msg": "config not found: " + cfg_path,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    configured = _parse_config(ctx.file_read(cfg_path))
    found = False
    for cfg_p, cfg_k in configured:
        if cfg_p == path and cfg_k == kind:
            found = True
    if not found:
        return {
            "changed": False,
            "msg": item + ": not in config",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    stat_res = ctx.run(["stat", "-c", "%Y", path], mutates=False)
    if stat_res.rc != 0:
        return {
            "changed": False,
            "msg": "stat failed: " + stat_res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    mtime_str = stat_res.stdout.strip()
    if not mtime_str.isdigit():
        return {
            "changed": False,
            "msg": "unexpected stat output: " + mtime_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    last_modify = int(mtime_str)

    now_res = ctx.run(["date", "+%s"], mutates=False)
    now_str = now_res.stdout.strip()
    now = int(now_str) if now_str.isdigit() else last_modify
    age = now - last_modify
    if age < 0:
        age = 0

    age_last_operation = params.get("age_last_operation", [])
    levels = {}
    for entry in age_last_operation:
        if len(entry) >= 3:
            levels[entry[0]] = (entry[1], entry[2])

    state = "OK"
    metrics = {"age_modify": age}
    summary = "Time since last modify: " + _fmt_duration(age)

    if "modify" in levels:
        warn, crit = levels["modify"]
        if age >= crit:
            state = "CRIT"
            summary = summary + " (!!)"
        elif age >= warn:
            state = "WARN"
            summary = summary + " (!)"

    detail_lines = []
    for mode in sorted(levels):
        if mode != "modify":
            detail_lines.append("Time since last %s: unknown (event type not trackable by polling)" % mode)
            if state == "OK":
                state = "UNKNOWN"

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": "\n".join(detail_lines)},
    }