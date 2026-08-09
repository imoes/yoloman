def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    base = ".1.3.6.1.4.1.116.5.11.4.1.1.6.1"

    # Detect: only run on actual Hitachi HUS devices via sysDescr
    descr_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if descr_res.rc != 0 or (
        len(descr_res.stdout) > 0
        and "hm700" not in descr_res.stdout
        and "hm800" not in descr_res.stdout
        and "hm850" not in descr_res.stdout
        and "hm900" not in descr_res.stdout
    ):
        if params.get("_discover"):
            return {"changed": False, "msg": "no Hitachi HUS device found", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "no Hitachi HUS device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Walk the DKC table (index under .1 -> item is the trailing OID index)
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1"], mutates=False)
    if res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no HUS DKC data", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "no HUS DKC data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    labels = (
        "Processor",
        "Internal Bus",
        "Cache",
        "Shared Memory",
        "Power Supply",
        "Battery",
        "Fan",
        "Environment",
    )

    hus_map = {
        "0": ("UNKNOWN", "unknown"),
        "1": ("OK", "no error"),
        "2": ("CRIT", "acute"),
        "3": ("CRIT", "serious"),
        "4": ("WARN", "moderate"),
        "5": ("WARN", "service"),
    }

    # Collect per-item raw value rows keyed by numeric index
    items = {}
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        suffix = oid[len(base) + 1:]
        # suffix looks like ".1.2" etc; split first sub-id as column, rest as index
        parts = suffix.split(".")
        # parts[0] is the trailing column number (1..9), parts[1:] is the item index
        col = parts[0]
        index = ".".join(parts[1:])
        if index not in items:
            items[index] = {}
        items[index][col] = value

    if params.get("_discover"):
        discovery = []
        for index in items:
            discovery.append({
                "item": index,
                "params": {},
                "metrics": ["processor", "internal_bus", "cache", "shared_memory", "power_supply", "battery", "fan", "environment"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    row = items.get(item)
    if row == None:
        return {
            "changed": False,
            "msg": "no such chassis: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch each column value for this item via snmpget -Oqv on <base>.<col>.<index>
    details = []
    worst_state = "OK"
    state_rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    metrics = {}

    for i, label in enumerate(labels):
        col = str(i + 1)
        if col not in row:
            # Query the scalar directly
            val_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + col + "." + item],
                mutates=False,
            )
            if val_res.rc != 0:
                value = "0"
            else:
                value = val_res.stdout.strip()
        else:
            value = row[col]

        state, desc = hus_map.get(value, ("UNKNOWN", "unknown"))
        details.append(label + ": " + desc)
        if state_rank.get(state, 0) > state_rank.get(worst_state, 0):
            worst_state = state

    return {
        "changed": False,
        "msg": "; ".join(details),
        "data": {
            "state": worst_state,
            "metrics": metrics,
            "details": "\n".join(details),
        },
    }