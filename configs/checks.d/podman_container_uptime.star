def _uptime_str(total_seconds):
    # Produce a human-readable uptime string, mirroring Checkmk's uptime formatting.
    total_seconds = int(total_seconds)
    days = total_seconds // 86400
    hours = (total_seconds % 86400) // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60
    if days > 0:
        return "%dd %d:%d:%d" % (days, hours, minutes, seconds)
    return "%d:%d:%d" % (hours, minutes, seconds)


def main(ctx, params):
    # ---- parameters ----
    warn = params.get("warn", 0.0)
    crit = params.get("crit", 0.0)
    levels = params.get("levels", None)
    if levels != None:
        warn = levels[0]
        crit = levels[1]

    # ---- probe: is podman installed? ----
    version_res = ctx.run(["podman", "--version"], mutates=False)
    if version_res.rc != 0 or version_res.skipped:
        if params.get("_discover"):
            return {"changed": False, "msg": "no podman found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "podman not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # ---- gather container list (read-only) ----
    # Use --format to get predictable machine-readable output: name|status|started_at
    list_res = ctx.run(
        ["podman", "ps", "-a", "--all", "--format", "{{.Names}}|{{.Status}}|{{.StartedAt}}"],
        mutates=False,
    )
    if list_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "podman ps failed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "podman ps failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    containers = []
    for line in list_res.stdout.splitlines():
        if not line:
            continue
        parts = line.split("|")
        if len(parts) < 3:
            continue
        name = parts[0]
        status = parts[1]
        started_at = parts[2]
        containers.append((name, status, started_at))

    # ---- discovery mode ----
    if params.get("_discover"):
        discovery = []
        for name, status, started_at in containers:
            if status in ("running", "exited"):
                discovery.append({
                    "item": name,
                    "params": {"warn": warn, "crit": crit},
                    "metrics": ["uptime"],
                })
        return {"changed": False,
                "msg": "discovered %d podman uptime services" % len(discovery),
                "data": {"discovery": discovery}}

    # ---- check mode: evaluate one item ----
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # find the item
    found = None
    for name, status, started_at in containers:
        if name == item:
            found = (name, status, started_at)
            break

    if found == None:
        return {"changed": False, "msg": "container not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name, status, started_at = found

    # If not running: report OK with operational state (mirrors the source check)
    if status != "running":
        return {"changed": False,
                "msg": "Operational state: " + status,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    # Parse started_at — podman --format prints a Go time string like
    # "2024-01-15 10:30:00.123456 +0000 UTC". We compute uptime via a
    # lightweight approach using podman's own inspect + a date calculation.
    # Try to get started-at as RFC3339 via podman inspect for reliability.
    inspect_res = ctx.run(
        ["podman", "inspect", "--format", "{{.State.StartedAt}}", item],
        mutates=False,
    )
    if inspect_res.rc != 0 or not inspect_res.stdout:
        return {"changed": False, "msg": "could not inspect container start time",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    started_iso = inspect_res.stdout.strip()
    # Trim Go-style suffix " UTC" -> "+00:00" for fromisoformat compatibility.
    started_clean = started_iso
    if started_clean.endswith("UTC"):
        started_clean = started_clean[:-3].strip() + "+00:00"
    elif started_clean.endswith(" +0000"):
        started_clean = started_clean[:-6] + "+00:00"

    # Compute uptime using the host's date command (no Python datetime available).
    now_res = ctx.run(["date", "+%s"], mutates=False)
    if now_res.rc != 0 or not now_res.stdout.strip().isdigit():
        return {"changed": False, "msg": "could not determine current time",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    now_epoch = int(now_res.stdout.strip())

    # Convert started_clean (ISO 8601) to epoch using date -d.
    date_conv = ctx.run(["date", "-d", started_clean, "+%s"], mutates=False)
    if date_conv.rc != 0 or not date_conv.stdout.strip().isdigit():
        return {"changed": False, "msg": "could not parse container start time",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    started_epoch = int(date_conv.stdout.strip())

    uptime_sec = float(now_epoch - started_epoch)
    if uptime_sec < 0:
        uptime_sec = 0.0

    # Apply thresholds: warn/crit are in SECONDS per the uptime ruleset.
    # Lower-bound rules apply (uptime below warn/crit).
    state = "OK"
    if crit != 0.0 and uptime_sec <= crit:
        state = "CRIT"
    elif warn != 0.0 and uptime_sec <= warn:
        state = "WARN"

    details = "Uptime: %s (%f seconds)" % (_uptime_str(uptime_sec), uptime_sec)
    msg = "Uptime %s" % _uptime_str(uptime_sec)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"uptime": uptime_sec},
                     "details": details}}