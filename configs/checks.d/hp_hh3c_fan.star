def main(ctx, params):
    if params.get("_discover"):
        # Probe for HP/H3C device presence via sysObjectID
        symoid_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False)
        if symoid_res.rc != 0 or not symoid_res.stdout.startswith(".1.3.6.1.4.1.25506"):
            return {"changed": False, "msg": "not an HP/H3C device",
                    "data": {"discovery": []}}

        # Fetch sysDescr to confirm presence of H3C or HPE
        sysdesc_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
            mutates=False)
        if sysdesc_res.rc != 0:
            return {"changed": False, "msg": "failed to fetch sysDescr",
                    "data": {"discovery": []}}

        desc = sysdesc_res.stdout.upper()
        if "H3C" not in desc and "HPE" not in desc:
            return {"changed": False, "msg": "device is not H3C or HPE",
                    "data": {"discovery": []}}

        # Walk fan table to discover items (OIDs: 1=number, 2=status)
        fan_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn",
             params.get("host", "localhost"), ".1.3.6.1.4.1.25506.8.35.9.1.1.1"],
            mutates=False)
        if fan_res.rc != 0 or not fan_res.stdout:
            return {"changed": False, "msg": "no fan data found",
                    "data": {"discovery": []}}

        base_oid = ".1.3.6.1.4.1.25506.8.35.9.1.1.1"
        fan_data = {}
        for line in fan_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid_suffix = parts[0][len(base_oid) + 1:]
            value = parts[1].strip()
            sub_id = oid_suffix.split(".")[0]
            index = oid_suffix[len(sub_id) + 1:]
            if sub_id == "1":
                fan_data[index] = int(value)

        discovery = []
        for num, status in fan_data.items():
            # UNSUPPORTED=4, NOT_INSTALLED=3 are skipped in discovery
            if status not in (3, 4):
                discovery.append({"item": num, "params": {},
                                  "metrics": []})

        return {"changed": False,
                "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    base_oid = ".1.3.6.1.4.1.25506.8.35.9.1.1.1"

    # Probe for HP/H3C device to validate presence
    symoid_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
         params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
        mutates=False)
    if symoid_res.rc != 0 or not symoid_res.stdout.startswith(".1.3.6.1.4.1.25506"):
        return {"changed": False, "msg": "not an HP/H3C device: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch fan status via snmpget on column .2 (status) for the item index
    get_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
         params.get("host", "localhost"), base_oid + ".2." + item],
        mutates=False)
    if get_res.rc != 0:
        return {"changed": False, "msg": "fan " + item + " not found or unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = int(get_res.stdout)
    # DEACTIVE=2 -> CRIT, ACTIVE=1 -> OK, others -> UNKNOWN
    if status == 2:
        state = "CRIT"
        summary = "Status: deactive"
    elif status == 1:
        state = "OK"
        summary = "Status: active"
    else:
        state = "UNKNOWN"
        summary = "Status: unknown (%d)" % status

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}