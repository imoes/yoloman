def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.2.3.51.2.2.3"],
            mutates=False,
        )
        if walk.rc != 0 or not walk.stdout:
            return {"changed": False, "msg": "no blade blowers found",
                    "data": {"discovery": [], "host_labels": {}}}

        rows = []
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            rows.append((line[:sp], line[sp + 1:]))

        max_idx = 0
        for oid, val in rows:
            if len(oid) > len(".1.3.6.1.4.1.2.3.51.2.2.3"):
                suffix = oid[len(".1.3.6.1.4.1.2.3.51.2.2.3") + 1:]
                if suffix.isdigit():
                    idx = int(suffix)
                    if idx > max_idx:
                        max_idx = idx

        speed_by_idx = {}
        state_by_idx = {}
        rpm_by_idx = {}
        for oid, val in rows:
            suffix = oid[len(".1.3.6.1.4.1.2.3.51.2.2.3") + 1:]
            idx = int(suffix)
            if suffix.startswith("0") and len(suffix) == 1:
                pass
            if oid.endswith(".0"):
                col = int(oid.split(".")[-2])
                if col == 1:
                    speed_by_idx[idx] = val
                elif col == 10:
                    state_by_idx[idx] = val
                elif col == 20:
                    rpm_by_idx[idx] = val

        n = 0
        for i in range(1, max_idx + 1):
            if i in state_by_idx:
                n += 1

        out = []
        for i in range(1, n + 1):
            st = state_by_idx.get(i, "")
            if st != "0":
                out.append({"item": "%d/%d" % (i, n),
                            "params": {}, "metrics": ["rpm", "perc"]})

        return {"changed": False,
                "msg": "discovered %d blowers" % len(out),
                "data": {"discovery": out, "host_labels": {}}}

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         ".1.3.6.1.4.1.2.3.51.2.2.3"],
        mutates=False,
    )
    if walk.rc != 0 or not walk.stdout:
        return {"changed": False, "msg": "no blade blowers reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = {}
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        suffix = oid[len(".1.3.6.1.4.1.2.3.51.2.2.3") + 1:]
        rows[suffix] = val

    if not item:
        return {"changed": False, "msg": "no blower item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = item.split("/")
    if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    blower = int(parts[0])
    num = int(parts[1])
    if num == 0:
        return {"changed": False, "msg": "invalid blower count",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    speed_suffix = str(blower - 1) + ".0"
    speed_val = rows.get(speed_suffix, "")

    state_suffix = str(blower - 1 + num) + ".0"
    state_val = rows.get(state_suffix, "")

    rpm_suffix = str(blower - 1 + 2 * num) + ".0"
    rpm_val = rows.get(rpm_suffix, "")

    metrics = {}
    output = ""

    if rpm_val and rpm_val.lstrip("-").isdigit():
        rpm = int(rpm_val)
        metrics["rpm"] = rpm
        output += "Speed at %d RPM" % rpm

    if speed_val and "%" in speed_val:
        num_part = speed_val.split("%")[0]
        if num_part.isdigit():
            perc = int(num_part)
            metrics["perc"] = perc
            if output == "":
                output += "Speed is at %d%% of max" % perc
            else:
                output += " (%d%% of max)" % perc

    if state_val == "1":
        if output == "":
            output = "OK"
        return {"changed": False, "msg": output,
                "data": {"state": "OK", "metrics": metrics, "details": ""}}

    if output == "":
        output = "Blower state unknown: %s" % state_val
    return {"changed": False, "msg": output,
            "data": {"state": "CRIT", "metrics": metrics, "details": ""}}