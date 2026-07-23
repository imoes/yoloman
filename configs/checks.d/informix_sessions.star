INFORMIX_DIRS = [
    "/opt/IBM/informix",
    "/opt/informix",
    "/usr/informix",
    "/home/informix",
    "/usr/local/informix",
]

DIGITS = "0123456789"

def _is_digits_only(s):
    if not s:
        return False
    for c in s:
        if c not in DIGITS:
            return False
    return True

def _find_informix_dir(ctx):
    for d in INFORMIX_DIRS:
        if ctx.file_exists(d + "/bin/onstat"):
            return d
    return ""

def _get_running_instances(ctx):
    res = ctx.run(["ps", "-eo", "pid,comm"], mutates=False)
    pids = []
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2 and "oninit" in parts[1]:
            pid = parts[0]
            if _is_digits_only(pid):
                pids.append(pid)

    instances = {}
    for pid in pids:
        env_path = "/proc/%s/environ" % pid
        if not ctx.file_exists(env_path):
            continue
        content = ctx.file_read(env_path)
        env = {}
        for part in content.split("\x00"):
            idx = part.find("=")
            if idx > 0:
                env[part[:idx]] = part[idx + 1:]
        server = env.get("INFORMIXSERVER", "")
        idir = env.get("INFORMIXDIR", "")
        if server and server not in instances:
            instances[server] = idir
    return instances

def _count_sessions(ctx, informix_dir, informix_server):
    onstat_bin = informix_dir + "/bin/onstat"
    res = ctx.run(
        ["env",
         "INFORMIXSERVER=" + informix_server,
         "INFORMIXDIR=" + informix_dir,
         onstat_bin, "-g", "ses"],
        mutates=False,
        ok_codes=[0, 1],
    )
    if res.rc != 0:
        return -1
    count = 0
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped and stripped[0] in DIGITS:
            count += 1
    return count

def main(ctx, params):
    if params.get("_discover"):
        instances = _get_running_instances(ctx)

        discovery = []
        for server in instances:
            discovery.append({
                "item": server,
                "params": {"levels": [50, 60]},
                "metrics": ["sessions"],
            })

        return {
            "changed": False,
            "msg": "discovered %d Informix instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    levels = params.get("levels", (50, 60))
    warn = levels[0]
    crit = levels[1]

    informix_dir = _find_informix_dir(ctx)
    if not informix_dir:
        return {
            "changed": False,
            "msg": "Informix not found in known paths",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "onstat not found"},
        }

    sessions = _count_sessions(ctx, informix_dir, item)

    if sessions < 0:
        return {
            "changed": False,
            "msg": "Cannot connect to Informix instance: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "onstat -g ses failed"},
        }

    if sessions >= crit:
        state = "CRIT"
    elif sessions >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Sessions: %d" % sessions,
        "data": {
            "state": state,
            "metrics": {"sessions": sessions},
            "details": "",
        },
    }