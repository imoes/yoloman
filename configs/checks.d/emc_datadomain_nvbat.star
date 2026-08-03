def main(ctx, params):
    if params.get("_discover"):
        # Probe for the product first: require an EMC Data Domain via SNMP
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if res.rc == 127 or not res.stdout.startswith("Data Domain OS"):
            return {"changed": False, "msg": "no EMC Data Domain detected",
                    "data": {"discovery": []}}

        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), ".1.3.6.1.4.1.19746.1.2.3.1.1"],
            mutates=False,
        )
        discovery = []
        for line in res.stdout.splitlines():
            parts = line.split(" ")
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = " ".join(parts[1:])
            suffix = oid[len(".1.3.6.1.4.1.19746.1.2.3.1.1") + 1:]
            idx = suffix.split(".")[-1]
            col = suffix.split(".")[-2]
            if col == "1":
                discovery.append({"index": idx, "name": value,
                                  "cols": {}})
            for d in discovery:
                if d["index"] == idx:
                    d["cols"][int(col)] = value
                    break

        out = []
        for d in discovery:
            c = d["cols"]
            if c.get(1) == d["name"] and 2 in c and 3 in c and 4 in c:
                out.append({"item": d["name"] + "-" + c["2"],
                            "metrics": ["battery_capacity"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    # Re-probe product presence in check mode too
    probe = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if probe.rc == 127 or not probe.stdout.startswith("Data Domain OS"):
        return {"changed": False,
                "msg": "no EMC Data Domain detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    table = {}
    for col in ["1", "2", "3", "4"]:
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.19746.1.2.3.1.1." + col],
            mutates=False,
        )
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1]
            idx = oid[len(".1.3.6.1.4.1.19746.1.2.3.1.1." + col) + 1:]
            table.setdefault(idx, {})[col] = val

    state_table = {
        "0": ("OK", "OK"),
        "1": ("Disabled", "WARN"),
        "2": ("Discharged", "CRIT"),
        "3": ("Softdisabled", "WARN"),
    }

    for idx, cols in table.items():
        if len(cols) < 4:
            continue
        cand = cols["1"] + "-" + cols["2"]
        if cand == item:
            dev_charge = cols["4"]
            dev_state = cols["3"]
            dev_state_str, dev_state_rc = state_table.get(
                dev_state, ("Unknown", "UNKNOWN"))
            metrics = {}
            if dev_charge.replace(".", "", 1).isdigit():
                metrics["battery_capacity"] = float(dev_charge)
            return {"changed": False,
                    "msg": "Status %s Charge Level %s%%" % (dev_state_str, dev_charge),
                    "data": {"state": dev_state_rc, "metrics": metrics, "details": ""}}

    return {"changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}