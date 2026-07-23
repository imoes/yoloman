# Mapping dicts must be defined at module top level (Starlark requirement)
LDRIVE_STATUS = {
    "1": ("CRIT", "offline"),
    "2": ("CRIT", "partially degraded"),
    "3": ("CRIT", "degraded"),
    "4": ("OK", "optimal"),
    "5": ("WARN", "unknown"),
}

LDRIVE_RAID = {
    "1": "0",
    "2": "1",
    "3": "1E",
    "4": "5",
    "5": "6",
    "6": "10",
    "7": "50",
    "8": "60",
    "9": "undefined",
}


def main(ctx, params):
    # Discover mode: enumerate logical drives
    if params.get("_discover"):
        res = ctx.run(
            [
                "snmpwalk",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                ".1.3.6.1.4.1.14685.3.1.259.1",
            ],
            mutates=False,
        )
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []},
            }

        lines = res.stdout.splitlines()
        items = []
        for line in lines:
            # Format: .1.3.6.1.4.1.14685.3.1.259.1.<index> = INTEGER: <value>
            idx = line.find(" = INTEGER: ")
            if idx == -1:
                continue
            oid_part = line[:idx]
            value_part = line[idx + len(" = INTEGER: "):]
            if not oid_part.endswith(".1"):
                continue  # we only want .1 (controller) entries to pair with later indices
            base_oid = oid_part.rsplit(".", 1)[0]
            controller = value_part.strip()
            # Read related fields: ldrive (.2), raid_level (.4), num_drives (.5), status (.6)
            ldrive_res = ctx.run(
                [
                    "snmpget",
                    "-v2c",
                    "-c",
                    params.get("community", "public"),
                    "-On",
                    params.get("host", "localhost"),
                    base_oid + ".2",
                ],
                mutates=False,
            )
            if ldrive_res.rc != 0 or ldrive_res.stdout.find(" = INTEGER: ") == -1:
                continue
            ldrive = ldrive_res.stdout.split(" = INTEGER: ")[1].strip()

            raid_res = ctx.run(
                [
                    "snmpget",
                    "-v2c",
                    "-c",
                    params.get("community", "public"),
                    "-On",
                    params.get("host", "localhost"),
                    base_oid + ".4",
                ],
                mutates=False,
            )
            if raid_res.rc != 0 or raid_res.stdout.find(" = INTEGER: ") == -1:
                continue
            raid_level = raid_res.stdout.split(" = INTEGER: ")[1].strip()

            drives_res = ctx.run(
                [
                    "snmpget",
                    "-v2c",
                    "-c",
                    params.get("community", "public"),
                    "-On",
                    params.get("host", "localhost"),
                    base_oid + ".5",
                ],
                mutates=False,
            )
            if drives_res.rc != 0 or drives_res.stdout.find(" = INTEGER: ") == -1:
                continue
                continue
            num_drives = drives_res.stdout.split(" = INTEGER: ")[1].strip()

            status_res = ctx.run(
                [
                    "snmpget",
                    "-v2c",
                    "-c",
                    params.get("community", "public"),
                    "-On",
                    params.get("host", "localhost"),
                    base_oid + ".6",
                ],
                mutates=False,
            )
            if status_res.rc != 0 or status_res.stdout.find(" = INTEGER: ") == -1:
                continue
            status = status_res.stdout.split(" = INTEGER: ")[1].strip()

            item_name = controller + "-" + ldrive
            items.append(
                {
                    "item": item_name,
                    "params": {},
                    "metrics": [],
                }
            )

        return {
            "changed": False,
            "msg": "discovered %d logical drives" % len(items),
            "data": {"discovery": items},
        }

    # Check mode: examine one logical drive
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse item to extract controller and ldrive
    parts = item.split("-", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    controller = parts[0]
    ldrive = parts[1]

    # Use snmpwalk to find the matching entry
    res = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.14685.3.1.259.1",
        ],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    found = False
    state_txt = "unknown"
    raid_level = "undefined"
    num_drives = "unknown"
    status = "5"  # default to 'unknown' status if not found
    lines = res.stdout.splitlines()
    for line in lines:
        idx = line.find(" = INTEGER: ")
        if idx == -1:
            continue
        oid_part = line[:idx]
        value_part = line[idx + len(" = INTEGER: "):]
        if not oid_part.endswith(".1"):
            continue
        base_oid = oid_part.rsplit(".", 1)[0]
        current_controller = value_part.strip()

        ldrive_res = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                base_oid + ".2",
            ],
            mutates=False,
        )
        if ldrive_res.rc != 0 or ldrive_res.stdout.find(" = INTEGER: ") == -1:
            continue
        current_ldrive = ldrive_res.stdout.split(" = INTEGER: ")[1].strip()

        if current_controller == controller and current_ldrive == ldrive:
            raid_res = ctx.run(
                [
                    "snmpget",
                    "-v2c",
                    "-c",
                    params.get("community", "public"),
                    "-On",
                    params.get("host", "localhost"),
                    base_oid + ".4",
                ],
                mutates=False,
            )
            if raid_res.rc == 0 and raid_res.stdout.find(" = INTEGER: ") != -1:
                raid_level = LDRIVE_RAID.get(raid_res.stdout.split(" = INTEGER: ")[1].strip(), "undefined")

            drives_res = ctx.run(
                [
                    "snmpget",
                    "-v2c",
                    "-c",
                    params.get("community", "public"),
                    "-On",
                    params.get("host", "localhost"),
                    base_oid + ".5",
                ],
                mutates=False,
            )
            if drives_res.rc == 0 and drives_res.stdout.find(" = INTEGER: ") != -1:
                num_drives = drives_res.stdout.split(" = INTEGER: ")[1].strip()

            status_res = ctx.run(
                [
                    "snmpget",
                    "-v2c",
                    "-c",
                    params.get("community", "public"),
                    "-On",
                    params.get("host", "localhost"),
                    base_oid + ".6",
                ],
                mutates=False,
            )
            if status_res.rc == 0 and status_res.stdout.find(" = INTEGER: ") != -1:
                status = status_res.stdout.split(" = INTEGER: ")[1].strip()
            found = True
            break

    if not found:
        return {
            "changed": False,
            "msg": "logical drive not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Look up status
    status_tuple = LDRIVE_STATUS.get(status, ("WARN", "unknown"))
    state, state_txt = status_tuple
    infotext = "Status: " + state_txt + ", RAID Level: " + raid_level + ", Number of Drives: " + num_drives

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": {},
            "details": infotext,
        },
    }
