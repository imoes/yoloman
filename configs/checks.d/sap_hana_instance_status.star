INSTANCE_STATUSES = {
    "0": "Error getting processes",
    "1": "Error getting processes",
    "2": "Timeout",
    "3": "OK",
    "4": "All processes stopped",
}

def _parse_elapsed_secs(s):
    parts = s.strip().split(":")
    if len(parts) != 3:
        return None
    if not parts[0].isdigit() or not parts[1].isdigit() or not parts[2].isdigit():
        return None
    return float(int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2]))

def _format_timespan(secs):
    total = int(secs)
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    if h > 0:
        return "%dh %dm %ds" % (h, m, s)
    if m > 0:
        return "%dm %ds" % (m, s)
    return "%ds" % s

def _find_instances(ctx):
    instances = []
    if not ctx.file_exists("/usr/sap"):
        return instances
    res = ctx.run(
        ["find", "/usr/sap", "-maxdepth", "2", "-type", "d", "-name", "HDB*"],
        mutates=False,
        ok_codes=[0, 1],
    )
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("/")
        if len(parts) < 5:
            continue
        sid = parts[3]
        hdb_dir = parts[4]
        if not hdb_dir.startswith("HDB"):
            continue
        nr = hdb_dir[3:]
        if len(nr) == 2 and nr.isdigit():
            instances.append({"sid": sid, "nr": nr, "item": "%s %s" % (sid, hdb_dir)})
    return instances

def _run_get_process_list(ctx, sid, nr):
    user = sid.lower() + "adm"
    return ctx.run(
        ["su", "-", user, "-c", "sapcontrol -nr %s -function GetProcessList" % nr],
        mutates=False,
        ok_codes=[0, 1, 2, 3, 4],
    )

def _parse_processes(stdout):
    processes = []
    in_data = False
    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("name,") or stripped.startswith("name ,"):
            in_data = True
            continue
        if not in_data:
            continue
        if not stripped:
            continue
        cols = [p.strip() for p in stripped.split(",")]
        if len(cols) < 7:
            continue
        processes.append({
            "name": cols[0],
            "description": cols[1],
            "state": cols[2],
            "elapsed": cols[5],
            "pid": cols[6],
        })
    return processes

def main(ctx, params):
    if params.get("_discover"):
        instances = _find_instances(ctx)
        out = []
        for inst in instances:
            out.append({
                "item": inst["item"],
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA instances" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    cols = item.split(" ")
    if len(cols) != 2 or not cols[1].startswith("HDB"):
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sid = cols[0]
    nr = cols[1][3:]

    res = _run_get_process_list(ctx, sid, nr)

    rc_str = str(res.rc)
    status_desc = INSTANCE_STATUSES.get(rc_str, "Error getting processes")

    if status_desc != "OK":
        return {
            "changed": False,
            "msg": status_desc,
            "data": {"state": "CRIT", "metrics": {}, "details": res.stderr},
        }

    processes = _parse_processes(res.stdout)

    overall_state = "OK"
    detail_lines = []
    warn_names = []

    for p in processes:
        elapsed_secs = _parse_elapsed_secs(p["elapsed"])
        timespan = "for " + _format_timespan(elapsed_secs) if elapsed_secs != None else ""
        detail_lines.append("%s: %s %s, PID: %s" % (p["name"], p["description"], timespan, p["pid"]))
        if p["state"] != "GREEN":
            overall_state = "WARN"
            warn_names.append("%s (%s)" % (p["name"], p["state"]))

    if warn_names:
        msg = "OK; not GREEN: " + ", ".join(warn_names)
    else:
        msg = "OK"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": {},
            "details": "\n".join(detail_lines),
        },
    }