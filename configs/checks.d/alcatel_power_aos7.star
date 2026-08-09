def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            [
                "snmpget",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqv",
                "-t",
                "5",
                params.get("host", "localhost"),
                ".1.3.6.1.2.1.1.2.0",
            ],
            mutates=False,
        )
        if res.rc == 127 or res.rc != 0:
            return {
                "changed": False,
                "msg": "host is not an Alcatel AOS7 device or SNMP unavailable",
                "data": {"discovery": [], "host_labels": {}},
            }

        sys_oid = res.stdout.strip().strip('"').strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.6486.801"):
            return {
                "changed": False,
                "msg": "not an Alcatel AOS7 device",
                "data": {"discovery": [], "host_labels": {}},
            }

        walk = ctx.run(
            [
                "snmpwalk",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqn",
                "-t",
                "5",
                params.get("host", "localhost"),
                ".1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1",
            ],
            mutates=False,
        )
        if walk.rc != 0:
            return {
                "changed": False,
                "msg": "no alcatel_power_aos7 data: %s" % walk.stderr.strip(),
                "data": {"discovery": []},
            }

        operability = {}
        ptype = {}
        column_operability = ".1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1.2"
        column_type = ".1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1.35"

        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            value = line[sp + 1:].strip()
            if oid.startswith(column_operability + "."):
                index = oid[len(column_operability) + 1:]
                operability[index] = value
            elif oid.startswith(column_type + "."):
                index = oid[len(column_type) + 1:]
                ptype[index] = value

        operability_mapping = {
            "1": "up",
            "2": "down",
            "3": "testing",
            "4": "unknown",
            "5": "secondary",
            "6": "not present",
            "7": "unpowered",
            "8": "master",
            "9": "idle",
            "10": "power save",
        }
        type_mapping = {
            "0": "no power supply",
            "1": "AC",
            "2": "DC",
        }

        out = []
        for index in operability:
            op = operability.get(index, "")
            status_readable = operability_mapping.get(op, "unknown")
            pt = ptype.get(index, "0")
            power_type = type_mapping.get(pt, "no power supply")
            if power_type == "no power supply" or status_readable == "not present":
                continue
            out.append(
                {
                    "item": index,
                    "params": {},
                    "metrics": [],
                }
            )

        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(out),
            "data": {
                "discovery": out,
                "host_labels": {"cmk/os_family": "network"},
            },
        }

    item = params.get("item", "")

    walk = ctx.run(
        [
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-Oqn",
            "-t",
            "5",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1.2",
        ],
        mutates=False,
    )
    if walk.rc != 0:
        return {
            "changed": False,
            "msg": "could not query power supply operability: %s" % walk.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    operability_value = ""
    found_item = False
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        value = line[sp + 1:].strip()
        base = ".1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1.2"
        if oid.startswith(base + "."):
            index = oid[len(base) + 1:]
            if index == item:
                operability_value = value
                found_item = True
                break

    type_walk = ctx.run(
        [
            "snmpget",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-Oqv",
            "-t",
            "5",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.6486.801.1.1.1.1.1.1.1.35." + item,
        ],
        mutates=False,
    )
    power_type_value = "0"
    if type_walk.rc == 0:
        power_type_value = type_walk.stdout.strip()

    operability_mapping = {
        "1": "up",
        "2": "down",
        "3": "testing",
        "4": "unknown",
        "5": "secondary",
        "6": "not present",
        "7": "unpowered",
        "8": "master",
        "9": "idle",
        "10": "power save",
    }
    type_mapping = {
        "0": "no power supply",
        "1": "AC",
        "2": "DC",
    }

    if not found_item:
        return {
            "changed": False,
            "msg": "no such power supply: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status_readable = operability_mapping.get(operability_value, "unknown")
    power_type = type_mapping.get(power_type_value, "no power supply")

    if power_type == "no power supply" or status_readable == "not present":
        return {
            "changed": False,
            "msg": "power supply %s is not present" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK" if status_readable == "up" else "CRIT"

    return {
        "changed": False,
        "msg": "[%s] Status: %s" % (power_type, status_readable),
        "data": {
            "state": state,
            "metrics": {},
            "details": "Power Supply %s: operability=%s, type=%s"
            % (item, status_readable, power_type),
        },
    }