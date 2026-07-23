def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        # OIDs: 10.1.2.100.4626, 20.1.2.100.4626, 10.1.2.100.4703, 20.1.2.100.4703, 10.1.2.100.4980, 20.1.2.100.4980
        oids = [
            ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.100.4626",
            ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.100.4626",
            ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.100.4703",
            ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.100.4703",
            ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.100.4980",
            ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.100.4980",
        ]
        data = {}
        used_names = set()
        counter = 2

        for oid in oids:
            res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
            if res.rc != 0:
                continue
            line = res.stdout.strip()
            if not line:
                continue
            # Format: OID = STRING: value or OID = STRING: "value"
            if " = STRING: " in line:
                value = line.split(" = STRING: ")[1].strip().strip('"')
            elif " = " in line:
                value = line.split(" = ")[1].strip().strip('"')
            else:
                continue

            # Extract name (last numeric part of OID after base)
            # Example: .1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.100.4626
            # We want to use 4626, 4703, 4980 as identifiers
            name = ""
            oid_parts = oid.split(".")
            if len(oid_parts) >= 2:
                # Get the last numeric identifier (e.g., 4626)
                name = oid_parts[-1]

            if not name:
                continue

            # Duplicate handling (like in parse_liebert_str_without_unit)
            if name in used_names:
                new_name = "%s %d" % (name, counter)
                counter += 1
                while new_name in used_names:
                    new_name = "%s %d" % (name, counter)
                    counter += 1
                name = new_name
            else:
                used_names.add(name)

            # Map event type to readable name (based on example output)
            # 4626 -> "Supply Chilled Water Over Temp"
            # 4703 -> "Chilled Water Control Valve Failure"
            # 4980 -> "Supply Chilled Water Loss of Flow"
            if name == "4626":
                base_name = "Supply Chilled Water Over Temp"
            elif name == "4703":
                base_name = "Chilled Water Control Valve Failure"
            elif name == "4980":
                base_name = "Supply Chilled Water Loss of Flow"
            else:
                base_name = name

            # Reapply duplicate handling with base_name
            if base_name in used_names:
                new_name = "%s %d" % (base_name, counter)
                counter += 1
                while new_name in used_names:
                    new_name = "%s %d" % (base_name, counter)
                    counter += 1
                base_name = new_name
            else:
                used_names.add(base_name)

            data[base_name] = value

        items = []
        for key in data:
            if key:
                items.append({
                    "item": key,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d chilled water events" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    oids = [
        ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.100.4626",
        ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.100.4626",
        ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.100.4703",
        ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.100.4703",
        ".1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.100.4980",
        ".1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.100.4980",
    ]
    data = {}
    used_names = set()
    counter = 2

    for oid in oids:
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        if res.rc != 0:
            continue
        line = res.stdout.strip()
        if not line:
            continue
        if " = STRING: " in line:
            value = line.split(" = STRING: ")[1].strip().strip('"')
        elif " = " in line:
            value = line.split(" = ")[1].strip().strip('"')
        else:
            continue

        name = ""
        oid_parts = oid.split(".")
        if len(oid_parts) >= 2:
            name = oid_parts[-1]

        if not name:
            continue

        if name in used_names:
            new_name = "%s %d" % (name, counter)
            counter += 1
            while new_name in used_names:
                new_name = "%s %d" % (name, counter)
                counter += 1
            name = new_name
        else:
            used_names.add(name)

        if name == "4626":
            base_name = "Supply Chilled Water Over Temp"
        elif name == "4703":
            base_name = "Chilled Water Control Valve Failure"
        elif name == "4980":
            base_name = "Supply Chilled Water Loss of Flow"
        else:
            base_name = name

        if base_name in used_names:
            new_name = "%s %d" % (base_name, counter)
            counter += 1
            while new_name in used_names:
                new_name = "%s %d" % (base_name, counter)
                counter += 1
            base_name = new_name
        else:
            used_names.add(base_name)

        data[base_name] = value

    value = data.get(item)
    if value == None:
        return {
            "changed": False,
            "msg": "event not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if value.lower() == "inactive event":
        return {
            "changed": False,
            "msg": "Normal",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }
    else:
        return {
            "changed": False,
            "msg": value,
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }