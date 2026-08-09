def main(ctx, params):
    """VMS Users check — single-service, read-only."""
    vms_present = _vms_detected(ctx)

    if params.get("_discover"):
        if not vms_present:
            return {
                "changed": False,
                "msg": "VMS not detected — check not applicable",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": ["sessions"]}
                ]
            },
        }

    if not vms_present:
        return {
            "changed": False,
            "msg": "No VMS system found — VMS Users check not applicable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _gather_vms_users(ctx)
    if section == None:
        return {
            "changed": False,
            "msg": "Failed to read VMS user information",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    infos = []
    num_sessions = 0
    for line in section:
        padding = [0] * (5 - len(line))
        rest = _map_saveint(line[1:]) + padding
        interactive = rest[0]
        if interactive:
            num_sessions += interactive
            infos.append(line[0] + ": " + str(interactive))

    if num_sessions:
        summary = "Interactive users: " + ", ".join(infos)
    else:
        summary = "No interactive users"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {"sessions": float(num_sessions)},
            "details": "",
        },
    }


def _map_saveint(fields):
    out = []
    for f in fields:
        out.append(_saveint(f))
    return out


def _saveint(i):
    if type(i) == "string" and i.isdigit():
        return int(i)
    if type(i) == "string" and len(i) > 0 and i[0] == "-" and i[1:].isdigit():
        return int(i)
    return 0


def _vms_detected(ctx):
    content = ""
    if ctx.file_exists("/etc/os_release"):
        content = ctx.file_read("/etc/os_release")
    for line in content.splitlines():
        low = line.lower()
        if low.startswith("name=") and "vms" in low:
            return True
        if low.startswith("id=") and "vms" in low:
            return True
    res = ctx.run(["sho", "usr"], mutates=False)
    if res.rc == 0:
        return True
    return False


def _gather_vms_users(ctx):
    res = ctx.run(["sho", "usr"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["show", "users"], mutates=False)
    if res.rc != 0:
        return None
    lines = []
    for raw in res.stdout.splitlines():
        fields = raw.split()
        if len(fields) > 0:
            lines.append(fields)
    return lines