def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            ["ioscan", "-fnC", "fc"],
            mutates=False,
        )
        hbas = parse_section(res.stdout)
        out = []
        for name in hbas.keys():
            out.append({
                "item": name,
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d HBAs" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    res = ctx.run(
        ["ioscan", "-fnC", "fc"],
        mutates=False,
    )
    hbas = parse_section(res.stdout)
    hba = hbas.get(item)
    if hba == None:
        return {
            "changed": False,
            "msg": "no HBA %s found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    state = "OK"
    infos = []

    hw_path = hba.get("Hardware Path is", "(unknown)")
    infos.append("Hardware Path: %s" % hw_path)

    driver_state = hba.get("Driver state", "(unknown)")
    infos.append("Driver State: %s" % driver_state)
    if driver_state != "ONLINE":
        state = "CRIT"
        infos[-1] += "(!!)"

    topology = hba.get("Topology", "(none)")
    infos.append("Topology: %s" % topology)
    if topology not in ["PTTOPT_FABRIC", "PRIVATE_LOOP", "PUBLIC_LOOP"]:
        state = "CRIT"
        infos[-1] += "(!!)"

    dump = hba.get("Driver-Firmware Dump Available", "NO")
    if dump != "NO":
        infos.append("Driver-Firmware Dump Available(!!)")
        state = "CRIT"

    return {
        "changed": False,
        "msg": ", ".join(infos),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }


def parse_section(text):
    hbas = {}
    hba = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        if line.startswith("/dev/"):
            name = line[5:].strip()
            hba = {"name": name}
            hbas[name] = hba
        else:
            parts = line.split("=", 1)
            if len(parts) == 2:
                key = parts[0].strip()
                val = parts[1].strip()
                if hba != {}:
                    hba[key] = val
    return hbas