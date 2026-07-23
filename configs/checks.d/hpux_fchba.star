VALID_TOPOLOGIES = ["PTTOPT_FABRIC", "PRIVATE_LOOP", "PUBLIC_LOOP"]

def _parse_fcmsutil(output):
    hba = {}
    for line in output.splitlines():
        if "=" in line:
            parts = line.split("=", 1)
            if len(parts) == 2:
                key = parts[0].strip()
                val = parts[1].strip()
                if key and val:
                    hba[key] = val
    return hba

def main(ctx, params):
    if params.get("_discover"):
        ls_res = ctx.run(["ls", "/dev/"], mutates=False)
        devices = []
        for name in ls_res.stdout.split():
            if name.startswith("fcd"):
                devices.append(name)

        discovery = []
        for dev in devices:
            res = ctx.run(["fcmsutil", "/dev/" + dev], mutates=False, ok_codes=[0, 1])
            if res.rc != 0:
                continue
            hba = _parse_fcmsutil(res.stdout)
            if hba.get("Driver state") == "ONLINE":
                discovery.append({
                    "item": dev,
                    "params": {},
                    "metrics": [],
                })

        return {
            "changed": False,
            "msg": "discovered %d FC HBAs" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    res = ctx.run(["fcmsutil", "/dev/" + item], mutates=False, ok_codes=[0, 1])

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "FC HBA not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    hba = _parse_fcmsutil(res.stdout)

    if not hba:
        return {
            "changed": False,
            "msg": "no data for: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK"
    infos = []

    hw_path = hba.get("Hardware Path is", "(unknown)")
    infos.append("Hardware Path: " + hw_path)

    driver_state = hba.get("Driver state", "(unknown)")
    if driver_state != "ONLINE":
        state = "CRIT"
        infos.append("Driver State: " + driver_state + "(!!)")
    else:
        infos.append("Driver State: " + driver_state)

    topology = hba.get("Topology", "(none)")
    if topology not in VALID_TOPOLOGIES:
        state = "CRIT"
        infos.append("Topology: " + topology + "(!!)")
    else:
        infos.append("Topology: " + topology)

    dump_avail = hba.get("Driver-Firmware Dump Available", "NO")
    if dump_avail != "NO":
        state = "CRIT"
        infos.append("Driver-Firmware Dump Available(!!)")

    return {
        "changed": False,
        "msg": ", ".join(infos),
        "data": {"state": state, "metrics": {}, "details": ""},
    }