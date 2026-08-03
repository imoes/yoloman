def main(ctx, params):
    if params.get("_discover"):
        stats = ctx.stat("/proc/vmsystem")
        if stats == None or stats.get("is_dir"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        content = ctx.file_read("/proc/vmsystem")
        lines = content.split("\n")
        found = False
        for line in lines:
            parts = line.strip().split()
            if len(parts) >= 3:
                if _is_float(parts[0]) and _is_float(parts[1]) and _is_float(parts[2]):
                    found = True
                    break
        if not found:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {},
                     "metrics": ["direct", "buffered"]}
                ]}}

    stats = ctx.stat("/proc/vmsystem")
    if stats == None or stats.get("is_dir"):
        return {"changed": False, "msg": "no vms_system data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    content = ctx.file_read("/proc/vmsystem")
    lines = content.split("\n")
    direct_ios = None
    buffered_ios = None
    procs = None
    for line in lines:
        parts = line.strip().split()
        if len(parts) >= 3 and _is_float(parts[0]) and _is_float(parts[1]) and _is_float(parts[2]):
            direct_ios = float(parts[0])
            buffered_ios = float(parts[1])
            procs = int(float(parts[2]))
            break

    if direct_ios == None or buffered_ios == None or procs == None:
        return {"changed": False, "msg": "no vms_system data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    details = "Direct IOs: %f/sec, Buffered IOs: %f/sec, Processes: %d" % (direct_ios, buffered_ios, procs)

    return {"changed": False, "msg": "Direct IOs: %f/sec, Buffered IOs: %f/sec" % (direct_ios, buffered_ios),
            "data": {"state": "OK",
                     "metrics": {"direct": direct_ios, "buffered": buffered_ios},
                     "details": details}}

def _is_float(s):
    if not s:
        return False
    stripped = s
    if stripped.startswith("-"):
        stripped = stripped[1:]
    if stripped == "":
        return False
    parts = stripped.split(".", 1)
    if len(parts) == 1:
        return parts[0].isdigit()
    if len(parts) == 2:
        int_part = parts[0] if parts[0] else ""
        frac_part = parts[1]
        return (int_part == "" or int_part.isdigit()) and (frac_part == "" or frac_part.isdigit()) and (int_part != "" or frac_part != "")
    return False