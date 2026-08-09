def main(ctx, params):
    if params.get("_discover"):
        # Discovery: confirm this is a Decru/Datafort device, then enumerate power supplies.
        sysDesc = ctx.run(["snmpget", "-v2c", "-c",
                           params.get("community", "public"), "-Oqv",
                           params.get("host", "localhost"),
                           ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sysDesc.rc != 0 or "datafort" not in sysDesc.stdout:
            return {"changed": False, "msg": "no Decru/Datafort device found",
                    "data": {"discovery": []}}
        res = ctx.run(["snmpwalk", "-v2c", "-c",
                       params.get("community", "public"), "-Oqn",
                       params.get("host", "localhost"),
                       ".1.3.6.1.4.1.12962.1.2.6.1.2"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no power supplies discovered",
                    "data": {"discovery": []}}
        # Map of index -> name for this column (col 2).
        names = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid, idx = parts[0], parts[0].split(".")[-1]
            names[idx] = parts[1]
        discovery = []
        for idx, name in names.items():
            discovery.append({"item": name, "params": {},
                              "metrics": []})
        return {"changed": False,
                "msg": "discovered %d power supplies" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    # Locate the index for this item by re-walking the name column.
    names_res = ctx.run(["snmpwalk", "-v2c", "-c",
                         params.get("community", "public"), "-Oqn",
                         params.get("host", "localhost"),
                         ".1.3.6.1.4.1.12962.1.2.6.1.2"], mutates=False)
    index = None
    if names_res.rc == 0:
        for line in names_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) >= 2 and parts[1] == item:
                index = parts[0].split(".")[-1]
                break
    if index == None:
        return {"changed": False, "msg": "power supply not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Read status column (col 3) for the matched index.
    st = ctx.run(["snmpget", "-v2c", "-c",
                  params.get("community", "public"), "-Oqv",
                  params.get("host", "localhost"),
                  ".1.3.6.1.4.1.12962.1.2.6.1.3." + index], mutates=False)
    if st.rc != 0:
        return {"changed": False, "msg": "could not read power status for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = st.stdout.strip()
    if status != "1":
        return {"changed": False,
                "msg": "power supply in state %s" % status,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "power supply ok",
            "data": {"state": "OK", "metrics": {}, "details": ""}}