# Checkmk hpux_tunables_shmseg — Number of shared memory segments
# Translated from the Checkmk agent-based check plugin.
# The underlying data is produced on HP-UX by `kctune` (or `kctune -I`).
# We probe `kctune` to confirm HP-UX presence, then read the tunable.

# Map tunable name -> (service_name, description_label, (warn, crit))
_TUNABLES = {
    "nkthread": ("Number of threads", "threads", (80.0, 85.0)),
    "nproc": ("Number of processes", "processes", (90.0, 96.0)),
    "maxfiles_lim": ("Number of open files", "files", (85.0, 90.0)),
    "semmni": ("Number of IPC Semaphore IDs", "semaphore_ids", (85.0, 90.0)),
    "shmseg": ("Number of shared memory segments", "segments", (85.0, 90.0)),
    "semmns": ("Number of IPC Semaphores", "entries", (85.0, 90.0)),
}


def _is_hpux(ctx):
    res = ctx.run(["uname", "-s"], mutates=False)
    if res.rc != 0:
        return False
    return res.stdout.strip() == "HP-UX"


def _kctune_present(ctx):
    res = ctx.run(["kctune", "-I"], mutates=False)
    # rc 127 means the binary is not present
    if res.rc == 127:
        return False
    return res.rc == 0


def _read_tunables(ctx):
    # Read all tunables at once via kctune -I which prints them.
    res = ctx.run(["kctune", "-I"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {}
    parsed = {}
    current_key = ""
    usage = 0
    for line in res.stdout.splitlines():
        s = line.strip()
        if not s:
            continue
        # A tunable line looks like: "shmseg  =  176  1000000  0.00%"
        # We treat the first token as the key when it's a bare identifier.
        if not s.startswith("Usage") and not s.startswith("Setting"):
            # Heuristic: if token before '=' is a known tunable, start new
            if "=" in s:
                key_part = s.split("=")[0].strip()
                if key_part:
                    current_key = key_part
                    # usage may be on same line: "key = 176 1000000 0.00%"
                    bits = s.replace("=", " ").split()
                    if len(bits) >= 3:
                        usage = int(bits[1])
                        threshold = int(bits[2])
                        parsed[current_key] = (usage, threshold)
            elif current_key and ("Usage" in s or "Setting" in s):
                pass
        elif current_key:
            if "Usage" in s:
                bits = s.split()
                # find integer value
                for b in bits:
                    if b.isdigit():
                        usage = int(b)
                        break
            elif "Setting" in s:
                bits = s.split()
                for b in bits:
                    if b.isdigit():
                        parsed[current_key] = (usage, int(b))
                        break
                current_key = ""
    return parsed


def _tune(parsed, name):
    return parsed.get(name)


def _grade(perc, warn, crit):
    if perc > crit:
        return "CRIT"
    if perc > warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    # Discovery mode: enumerate which tunables are available.
    if params.get("_discover"):
        if not _is_hpux(ctx) or not _kctune_present(ctx):
            return {"changed": False, "msg": "not on HP-UX or kctune missing",
                    "data": {"discovery": []}}
        parsed = _read_tunables(ctx)
        if not parsed:
            return {"changed": False, "msg": "no tunables found",
                    "data": {"discovery": []}}
        discovery = []
        for name, (svc, label, levels) in _TUNABLES.items():
            if name in parsed:
                discovery.append({
                    "item": name,
                    "params": {"levels": list(levels)},
                    "metrics": [label],
                })
        return {"changed": False, "msg": "discovered %d tunables" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode: evaluate one item.
    item = params.get("item", "")
    if item not in _TUNABLES:
        return {"changed": False, "msg": "no such tunable: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    svc, label, default_levels = _TUNABLES[item]
    parsed = _read_tunables(ctx)
    if item not in parsed:
        return {"changed": False, "msg": "tunable %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    usage, threshold = parsed[item]
    levels = params.get("levels", list(default_levels))
    warn = levels[0] if len(levels) >= 1 else default_levels[0]
    crit = levels[1] if len(levels) >= 2 else default_levels[1]
    if threshold == 0:
        perc = 0.0
    else:
        perc = float(usage) / float(threshold) * 100
    state = _grade(perc, warn, crit)
    warn_perf = float(warn * threshold / 100)
    crit_perf = float(crit * threshold / 100)
    msg = "%f%% used (%d/%d %s)" % (perc, usage, threshold, label)
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {label: usage},
                     "details": "(warn/crit at %s/%s)" % (warn, crit)}}