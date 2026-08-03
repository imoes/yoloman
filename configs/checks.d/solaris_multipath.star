def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["multipathing", "show", " topology"], mutates=False)
        if res.rc != 0 or res.rc == 127:
            # Try reading from the kernel directly as a fallback data source
            res = ctx.run(["kstat", "-p", "mp", "path_state"], mutates=False)
            if res.rc != 0 or res.rc == 127:
                return {"changed": False, "msg": "no solaris multipathing found", "data": {"discovery": []}}

        # Parse the topology output to find devices and their path counts
        discovery = []
        lines = res.stdout.splitlines()
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("/dev/rdsk/"):
                # Parse device path - extract device name
                device = line
                # Look for path counts in subsequent lines or same line
                parts = line.split()
                if len(parts) >= 3 and parts[-1].isdigit() and parts[-2].isdigit():
                    total = int(parts[-2])
                    operational = int(parts[-1])
                    item = device.split("/")[-1]
                    discovery.append({"item": item, "params": {"levels": operational}, "metrics": []})
            i += 1

        return {
            "changed": False,
            "msg": "discovered %d multipath devices" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    # Re-read the topology to get current path state for this specific device
    res = ctx.run(["multipathing", "show", "topology"], mutates=False)
    if res.rc != 0 or res.rc == 127:
        res2 = ctx.run(["kstat", "-p", "mp", "path_state"], mutates=False)
        if res2.rc != 0 or res2.rc == 127:
            return {
                "changed": False,
                "msg": "multipathing not available on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "multipathing tools not found"},
            }
        res = res2

    lines = res.stdout.splitlines()
    operational_int = 0
    total_int = 0
    found = False

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("/dev/rdsk/"):
            device_item = line.split("/")[-1]
            if item == "" or device_item == item:
                parts = line.split()
                if len(parts) >= 3 and parts[-1].isdigit() and parts[-2].isdigit():
                    total_int = int(parts[-2])
                    operational_int = int(parts[-1])
                    found = True
                    break
        i += 1

    if not found:
        if item == "":
            return {
                "changed": False,
                "msg": "no multipath devices found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no multipath devices present"},
            }
        return {
            "changed": False,
            "msg": "multipath device %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "device %s not present" % item},
        }

    infotext = "%d paths operational, %d paths total" % (operational_int, total_int)
    levels = params.get("levels")
    if levels == None:
        return {
            "changed": False,
            "msg": infotext + ", expected paths unknown, please redo service discovery",
            "data": {"state": "WARN", "metrics": {"operational": operational_int, "total": total_int}, "details": infotext},
        }

    state = "OK"
    details = infotext

    if type(levels) == "list":
        # levels is a list/tuple [warn, crit] interpreted as percentages
        warn = levels[0]
        crit = levels[1]
        warn_num = (warn / 100.0) * total_int
        crit_num = (crit / 100.0) * total_int
        levels_text = " (Warning/ Critical at %d/ %d)" % (warn_num, crit_num)
        info = "paths active: %d" % operational_int
        details = info + levels_text
        if operational_int <= crit_num:
            state = "CRIT"
        elif operational_int <= warn_num:
            state = "WARN"
        else:
            state = "OK"
            details = info
    else:
        expected = int(levels)
        if operational_int > expected:
            state = "WARN"
        elif expected == operational_int:
            state = "OK"
        elif expected >= operational_int * 2:
            state = "CRIT"
        else:
            state = "WARN"
        if state != "OK":
            details = infotext + ", %d paths expected to be operational" % expected
        else:
            details = infotext

    return {
        "changed": False,
        "msg": details,
        "data": {"state": state, "metrics": {"operational": operational_int, "total": total_int}, "details": details},
    }