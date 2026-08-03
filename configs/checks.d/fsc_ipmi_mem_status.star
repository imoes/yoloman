def main(ctx, params):
    rows = _gather(ctx)

    # No IPMI sensor source on this host -> the check does not apply.
    if rows == None:
        return {
            "changed": False,
            "msg": "no IPMI memory sensor source available on this host",
            "data": {"discovery": []},
        }

    if params.get("_discover"):
        discovery = []
        for line in rows:
            if line[0] != "E" and len(line) > 2 and line[2] != "00":
                discovery.append({
                    "item": line[1],
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d IPMI memory slots" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    for line in rows:
        if line[0] == "E":
            return {
                "changed": False,
                "msg": "Error in IPMI sensor output: %s" % " ".join(line[1:]),
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": "",
                },
            }
        if line[1] == item:
            code = int(line[2])
            label = _status_label(code)
            state = _state_for(code)
            return {
                "changed": False,
                "msg": label,
                "data": {
                    "state": state,
                    "metrics": {},
                    "details": "",
                },
            }

    return {
        "changed": False,
        "msg": "item %s not found" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }


def _gather(ctx):
    probe = ctx.run(
        ["ipmitool", "sensor", "list", "memory"],
        mutates=False,
    )
    if probe.rc == 127:
        return None
    if not probe.stdout:
        probe = ctx.run(
            ["ipmitool", "sdr", "list", "memory"],
            mutates=False,
        )
        if not probe.stdout:
            return None

    rows = []
    for line in probe.stdout.splitlines():
        parts = line.split()
        if parts and parts[0] == "E":
            rows.append(parts)
            continue
        if len(parts) >= 3:
            rows.append(parts)
    return rows


def _status_label(code):
    table = {
        0: "Empty slot",
        1: "OK, running",
        2: "Reserved",
        3: "Error (module has encountered errors, but is still in use)",
        4: "Fail (module has encountered errors and is therefore disabled)",
        5: "Prefail (module exceeded the correctable errors threshold)",
    }
    return table.get(code, "Unknown status code %d" % code)


def _state_for(code):
    # 00 = Empty slot -> OK (slot present but unused)
    # 01 = OK, running -> OK
    # 02 = Reserved -> OK
    # 03 = Error -> CRIT
    # 04 = Fail -> CRIT
    # 05 = Prefail -> WARN
    mapping = {
        0: "OK",
        1: "OK",
        2: "OK",
        3: "CRIT",
        4: "CRIT",
        5: "WARN",
    }
    return mapping.get(code, "UNKNOWN")