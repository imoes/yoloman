def main(ctx, params):
    sysdesc = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
         params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sysdesc.rc != 0 or sysdesc.stdout.find("cisco") == -1:
        return {"changed": False, "msg": "no Cisco device found at host",
                "data": {"discovery": [], "state": "UNKNOWN", "metrics": {}, "details": ""}}

    base = ".1.3.6.1.4.1.9.9.13.1.5.1"

    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
         params.get("host", "localhost"), base + ".2"],
        mutates=False,
    )
    if walk.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed for cisco_power",
                "data": {"discovery": [], "state": "UNKNOWN", "metrics": {}, "details": ""}}

    rows = {}
    sids = []
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, val = parts[0], parts[1]
        idx = oid[len(base) + 1:]
        if idx == "":
            continue
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        rows[idx] = val
        sids.append(idx)

    cisco_power_states = {
        "1": "normal", "2": "warning", "3": "critical",
        "4": "shutdown", "5": "not present", "6": "not functioning",
    }
    cisco_power_sources = {
        "1": "unknown", "2": "AC", "3": "DC",
        "4": "external power supply", "5": "internal redundant",
    }

    if params.get("_discover"):
        states = {}
        sources = {}
        for idx in sids:
            sget = ctx.run(
                ["snmpget", "-v2c", "-c", params.get("community", "public"),
                 "-Oqv", params.get("host", "localhost"), base + ".3." + idx],
                mutates=False,
            )
            pget = ctx.run(
                ["snmpget", "-v2c", "-c", params.get("community", "public"),
                 "-Oqv", params.get("host", "localhost"), base + ".4." + idx],
                mutates=False,
            )
            states[idx] = sget.stdout.strip()
            sources[idx] = pget.stdout.strip()

        discovered = {}
        order = []
        for idx in sids:
            state = states.get(idx, "5")
            if state == "5":
                continue
            name = _item_name(rows.get(idx, ""))
            if name not in discovered:
                discovered[name] = []
                order.append(name)
            discovered[name].append(idx)

        out = []
        for name in order:
            entries = discovered[name]
            if len(entries) == 1:
                out.append({"item": name, "params": {}, "metrics": []})
            else:
                for entry in entries:
                    out.append({"item": name + " " + entry, "params": {}, "metrics": []})

        return {"changed": False,
                "msg": "discovered %d power supplies" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    matched_idx = None
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, val = parts[0], parts[1]
        idx = oid[len(base) + 1:]
        if idx == "":
            continue
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]

        name = _item_name(val)
        if item in (name, name + " " + idx, name + "/" + idx):
            matched_idx = idx
            break

    if matched_idx == None:
        return {"changed": False, "msg": "power supply not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    idx = matched_idx
    sget = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
         params.get("host", "localhost"), base + ".3." + idx],
        mutates=False,
    )
    pget = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
         params.get("host", "localhost"), base + ".4." + idx],
        mutates=False,
    )

    state = int(sget.stdout.strip())
    source = int(pget.stdout.strip())
    state_map = {"1": "OK", "2": "WARN"}.get(str(state), "CRIT")

    return {"changed": False,
            "msg": "Status: " + cisco_power_states.get(str(state), "unknown") +
                   ", Source: " + cisco_power_sources.get(str(source), "unknown"),
            "data": {"state": state_map, "metrics": {}, "details": ""}}


def _item_name(description):
    parts = [x.strip() for x in description.split(",")]
    if len(parts) == 1:
        device_description = description
    elif "#" in parts[-1] or "Power" in parts[-1]:
        device_description = " ".join(parts)
    elif parts[-1].startswith("PS"):
        device_description = " ".join([parts[0], parts[-1].split(" ")[0]])
    elif len(parts) >= 2 and parts[-2].startswith("PS"):
        device_description = " ".join(parts[:-2] + parts[-2].split(" ")[:-1])
    elif len(parts) >= 2 and parts[-2].startswith("Status"):
        device_description = " ".join(parts[:-2])
    else:
        device_description = " ".join(parts[:-1])

    name = device_description.replace("#", " ")
    return name or "supply"