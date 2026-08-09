def main(ctx, params):
    if params.get("_discover"):
        # Probe: is this a Rittal CMCIII LCP?
        sys_desc = ctx.run([
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            ".1.3.6.1.2.1.1.1.0",
        ], mutates=False)
        if sys_desc.rc != 0 or sys_desc.rc == 127:
            return {"changed": False, "msg": "no Rittal CMCIII detected",
                    "data": {"discovery": []}}

        # Check for the temperature description OID (LCP presence)
        temp_desc = ctx.run([
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6",
        ], mutates=False)
        if temp_desc.rc != 0:
            return {"changed": False, "msg": "no Rittal CMCIII LCP detected",
                    "data": {"discovery": []}}

        # Walk the IO sensors table
        io_walk = ctx.run([
            "snmpwalk", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqn",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.2606.7.4.2.2.1.3.1",
        ], mutates=False)
        if io_walk.rc != 0 or io_walk.rc == 127:
            return {"changed": False, "msg": "no IO sensors found",
                    "data": {"discovery": []}}

        discovery = []
        for line in io_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            # Extract index from OID: base is .1.3.6.1.4.1.2606.7.4.2.2.1.3.1
            # The index follows after the base OID
            base_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.1"
            suffix = oid[len(base_oid) + 1:]
            if not suffix:
                continue
            sensor_id = suffix

            # Fetch sensor details via SNMP GET
            # DescName is typically at a sub-OID of the sensor
            desc_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.1." + sensor_id + ".5"
            loc_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.1." + sensor_id + ".7"
            idx_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.1." + sensor_id + ".8"

            desc_res = ctx.run([
                "snmpget", "-v2c",
                "-c", params.get("community", "public"),
                "-Oqv",
                params.get("host", "localhost"),
                desc_oid,
            ], mutates=False)

            item = sensor_id
            if params.get("use_sensor_description", False) and desc_res.rc == 0:
                loc_res = ctx.run([
                    "snmpget", "-v2c",
                    "-c", params.get("community", "public"),
                    "-Oqv",
                    params.get("host", "localhost"),
                    loc_oid,
                ], mutates=False)
                idx_res = ctx.run([
                    "snmpget", "-v2c",
                    "-c", params.get("community", "public"),
                    "-Oqv",
                    params.get("host", "localhost"),
                    idx_oid,
                ], mutates=False)
                loc = loc_res.stdout.strip() if loc_res.rc == 0 else ""
                idx_val = idx_res.stdout.strip() if idx_res.rc == 0 else ""
                item = "%s-%s %s" % (loc, idx_val, desc_res.stdout.strip())

            discovery.append({
                "item": item,
                "params": {"_item_key": sensor_id},
                "metrics": [],
            })

        return {"changed": False,
                "msg": "discovered %d IO sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    item_key = params.get("_item_key", item)

    # Probe for the sensor's Status field
    status_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.1." + item_key + ".2"
    status_res = ctx.run([
        "snmpget", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv",
        params.get("host", "localhost"),
        status_oid,
    ], mutates=False)

    if status_res.rc != 0:
        return {"changed": False,
                "msg": "no IO sensor found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    entry = {"Status": status_res.stdout.strip()}

    # Fetch optional fields: Logic, Delay, Relay
    logic_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.1." + item_key + ".3"
    delay_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.1." + item_key + ".4"
    relay_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.1." + item_key + ".6"

    for key, oid_key in [("Logic", logic_oid), ("Delay", delay_oid), ("Relay", relay_oid)]:
        res = ctx.run([
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv",
            params.get("host", "localhost"),
            oid,
        ], mutates=False)
        if res.rc == 0:
            entry[key] = res.stdout.strip()

    # Map status to state
    state_map = {
        "OK": "OK",
        "Off": "OK",
        "On": "WARN",
        "Open": "WARN",
        "Closed": "OK",
    }
    state = state_map.get(entry["Status"], "WARN")

    return {"changed": False,
            "msg": "Status: %s" % entry["Status"],
            "data": {"state": state, "metrics": {}, "details": ""}}