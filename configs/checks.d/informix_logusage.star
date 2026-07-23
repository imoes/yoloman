INFORMIX_DIRS = [
    "/opt/informix",
    "/usr/informix",
    "/opt/IBM/informix",
    "/usr/local/informix",
]

SQLHOSTS_PATHS = [
    "/etc/informix/sqlhosts",
    "/usr/informix/etc/sqlhosts",
    "/opt/informix/etc/sqlhosts",
]

def _is_hex(s):
    if len(s) < 6:
        return False
    for c in s.lower():
        if c not in "0123456789abcdef":
            return False
    return True

def _fmt_bytes(b):
    if b >= 1073741824:
        return "%f GB" % (b / 1073741824.0)
    if b >= 1048576:
        return "%f MB" % (b / 1048576.0)
    if b >= 1024:
        return "%f KB" % (b / 1024.0)
    return "%d B" % b

def _worst_state(s1, s2):
    prio = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}
    if prio.get(s1, 0) >= prio.get(s2, 0):
        return s1
    return s2

def _state_from_upper(value, warn, crit):
    if crit != None and value >= crit:
        return "CRIT"
    if warn != None and value >= warn:
        return "WARN"
    return "OK"

def _parse_log_entries(output):
    entries = []
    in_logical = False
    in_table = False
    for line in output.splitlines():
        if "Logical Logging" in line:
            in_logical = True
        if not in_logical:
            continue
        if "address  number" in line or "address number" in line:
            in_table = True
            continue
        if in_table:
            stripped = line.strip()
            if not stripped:
                in_table = False
                continue
            parts = stripped.split()
            if len(parts) >= 7 and _is_hex(parts[0]):
                size_str = parts[5]
                used_str = parts[6]
                if size_str.isdigit() and used_str.isdigit():
                    entries.append({"size": int(size_str), "used": int(used_str)})
    return entries

def _find_informix_dir(ctx):
    for d in INFORMIX_DIRS:
        if ctx.file_exists(d + "/bin/onstat"):
            return d
    return ""

def _find_onstat(ctx, informix_dir):
    if informix_dir:
        return informix_dir + "/bin/onstat"
    res = ctx.run(["which", "onstat"], mutates=False, ok_codes=[0, 1])
    if res.rc == 0:
        path = res.stdout.strip()
        if path:
            return path
    return "onstat"

def _build_cmd(instance, informix_dir, onstat, extra_args):
    cmd = ["env"]
    if instance:
        cmd = cmd + ["INFORMIXSERVER=" + instance]
    if informix_dir:
        cmd = cmd + ["INFORMIXDIR=" + informix_dir]
    return cmd + [onstat] + extra_args

def _get_page_size(ctx, informix_dir, instance, onstat):
    cmd = _build_cmd(instance, informix_dir, onstat, ["-g", "cfg"])
    res = ctx.run(cmd, mutates=False, ok_codes=[0, 1, 2, 3])
    if res.rc == 0:
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("PAGESIZE"):
                parts = stripped.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    return int(parts[1]) * 1024
    return 4096

def _read_sqlhosts_instances(ctx):
    for path in SQLHOSTS_PATHS:
        if ctx.file_exists(path):
            content = ctx.file_read(path)
            instances = []
            for line in content.splitlines():
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                parts = stripped.split()
                if len(parts) >= 1 and parts[0] not in instances:
                    instances.append(parts[0])
            return instances
    return []

def main(ctx, params):
    informix_dir = _find_informix_dir(ctx)
    onstat = _find_onstat(ctx, informix_dir)

    if params.get("_discover"):
        candidates = _read_sqlhosts_instances(ctx)
        disc = []
        for inst in candidates:
            cmd = _build_cmd(inst, informix_dir, onstat, ["-l"])
            res = ctx.run(cmd, mutates=False, ok_codes=[0, 1, 2, 3, 255])
            if res.rc == 0 and "Logical Logging" in res.stdout:
                entries = _parse_log_entries(res.stdout)
                if entries:
                    disc.append({
                        "item": inst,
                        "params": {"levels_perc": [80.0, 85.0]},
                        "metrics": ["file_count", "log_files_total", "log_files_used", "log_files_used_perc"],
                    })
        if not disc:
            cmd = _build_cmd("", informix_dir, onstat, ["-l"])
            res = ctx.run(cmd, mutates=False, ok_codes=[0, 1, 2, 3])
            if res.rc == 0 and "Logical Logging" in res.stdout:
                entries = _parse_log_entries(res.stdout)
                if entries:
                    disc.append({
                        "item": "default",
                        "params": {"levels_perc": [80.0, 85.0]},
                        "metrics": ["file_count", "log_files_total", "log_files_used", "log_files_used_perc"],
                    })
        return {
            "changed": False,
            "msg": "discovered %d informix instances" % len(disc),
            "data": {"discovery": disc},
        }

    # Check mode
    item = params.get("item", "")
    levels_perc = params.get("levels_perc", [80.0, 85.0])
    levels = params.get("levels", None)

    warn_perc = float(levels_perc[0]) if len(levels_perc) >= 1 else 80.0
    crit_perc = float(levels_perc[1]) if len(levels_perc) >= 2 else 85.0
    warn_size = None
    crit_size = None
    if levels != None and len(levels) >= 2:
        warn_size = levels[0]
        crit_size = levels[1]
    elif levels != None and len(levels) >= 1:
        warn_size = levels[0]

    actual_instance = "" if item == "default" else item
    page_size = _get_page_size(ctx, informix_dir, actual_instance, onstat)

    cmd = _build_cmd(actual_instance, informix_dir, onstat, ["-l"])
    res = ctx.run(cmd, mutates=False, ok_codes=[0, 1, 2, 3])

    if res.rc != 0 or "Logical Logging" not in res.stdout:
        return {
            "changed": False,
            "msg": "cannot connect to Informix instance: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": res.stderr,
            },
        }

    entries = _parse_log_entries(res.stdout)
    logfiles = len(entries)

    if not logfiles:
        return {
            "changed": False,
            "msg": "Log information missing",
            "data": {"state": "WARN", "metrics": {}, "details": ""},
        }

    total_size = 0
    total_used = 0
    for entry in entries:
        total_size += entry["size"] * page_size
        total_used += entry["used"] * page_size

    used_perc = 0.0
    if total_size > 0:
        used_perc = total_used * 100.0 / total_size

    state = "OK"
    state = _worst_state(state, _state_from_upper(total_size, warn_size, crit_size))
    state = _worst_state(state, _state_from_upper(used_perc, warn_perc, crit_perc))

    msg = "Files: %d, Size: %s, Used: %s, Usage: %f%%" % (
        logfiles, _fmt_bytes(total_size), _fmt_bytes(total_used), used_perc
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "file_count": logfiles,
                "log_files_total": total_size,
                "log_files_used": total_used,
                "log_files_used_perc": used_perc,
            },
            "details": "",
        },
    }