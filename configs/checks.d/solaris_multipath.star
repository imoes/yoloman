def main(ctx, params):
    if params.get("_discover"):
        # Gather multipath data by running a shell command that parses the device output
        res = ctx.run(["bash", "-c", "for f in /dev/rdsk/*; do if echo \"$f\" | grep -qE '^/dev/rdsk/c[0-9]+t[0-9a-fA-F]+d0s[0-9]+$'; then echo \"$f\"; fi; done 2>/dev/null | head -100"], mutates=False, ok_codes=[0])
        out = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3:
                device = parts[0]
                total_str = parts[1]
                operational_str = parts[2]
                if device.startswith("/dev/rdsk/c") and device.endswith("s2") and total_str.isdigit() and operational_str.isdigit():
                    item = device.split("/")[-1]
                    out.append({
                        "item": item,
                        "params": {"levels": int(operational_str)},
                        "metrics": ["operational_paths"]
                    })
        return {
            "changed": False,
            "msg": "discovered %d multipath devices" % len(out),
            "data": {"discovery": out}
        }

    item = params.get("item", "")
    res = ctx.run(["bash", "-c", "for f in /dev/rdsk/*; do if echo \"$f\" | grep -qE '^/dev/rdsk/c[0-9]+t[0-9a-fA-F]+d0s[0-9]+$'; then echo \"$f\"; fi; done 2>/dev/null"], mutates=False, ok_codes=[0])
    found = False
    operational_int = 0
    total_int = 0

    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            device = parts[0]
            total_str = parts[1]
            operational_str = parts[2]
            if device.startswith("/dev/rdsk/c") and device.endswith("s2") and total_str.isdigit() and operational_str.isdigit():
                if device.split("/")[-1] == item:
                    found = True
                    total_int = int(total_str)
                    operational_int = int(operational_str)

    if not found:
        return {
            "changed": False,
            "msg": "multipath device not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    infotext = "%d paths operational, %d paths total" % (operational_int, total_int)
    levels = params.get("levels")
    state = "OK"

    if levels == None:
        state = "WARN"
        infotext = infotext + ", expected paths unknown, please redo service discovery"
    elif type(levels) == "int":
        expected = levels
        if operational_int > expected:
            state = "WARN"
            infotext = infotext + ", %d paths expected to be operational" % expected
        elif operational_int < expected:
            if expected >= operational_int * 2:
                state = "CRIT"
            else:
                state = "WARN"
            infotext = infotext + ", %d paths expected to be operational" % expected
    elif type(levels) == "list" and len(levels) == 2:
        warn_pct = levels[0]
        crit_pct = levels[1]
        warn_num = (warn_pct / 100.0) * float(total_int)
        crit_num = (crit_pct / 100.0) * float(total_int)
        if float(operational_int) <= crit_num:
            state = "CRIT"
        elif float(operational_int) <= warn_num:
            state = "WARN"
        levels_text = " (Warning/Critical at %f/%f)" % (warn_num, crit_num)
        infotext = "paths active: %d%s" % (operational_int, levels_text)
    else:
        state = "WARN"
        infotext = infotext + ", invalid levels format"

    return {
        "changed": False,
        "msg": infotext,
        "data": {"state": state, "metrics": {"operational_paths": operational_int}, "details": ""}
    }