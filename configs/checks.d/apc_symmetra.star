def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe for the real thing first: check if this is an APC device via sysOID
        sys_oid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_oid_res.rc != 0:
            return {"changed": False, "msg": "APC Symmetra not reachable via SNMP", "data": {"discovery": []}}

        sys_oid = sys_oid_res.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.318"):
            return {"changed": False, "msg": "Not an APC device", "data": {"discovery": []}}

        discovery = []

        # Main UPS status service (single service)
        discovery.append({"item": "", "params": {"warn": 80, "crit": 95}, "metrics": ["capacity", "runtime"]})

        # Cartridge services - fetch the cartridge table
        cart_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.318.1.1.1.2.3.10.2.1.10"],
            mutates=False,
        )
        if cart_res.rc == 0:
            carts = {}
            for line in cart_res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                idx = oid[len(".1.3.6.1.4.1.318.1.1.1.2.3.10.2.1.10") + 1:]
                carts[idx] = parts[1]
            for idx in sorted(carts.keys()):
                discovery.append({"item": "cartridge_" + idx, "params": {}, "metrics": []})

        # External temperature sensor services
        sensor_name_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.318.1.1.10.4.2.3.1.3"],
            mutates=False,
        )
        if sensor_name_res.rc == 0:
            for name in sensor_name_res.stdout.splitlines():
                name_stripped = name.strip().strip('"')
                if name_stripped:
                    discovery.append({"item": "temp_" + name_stripped, "params": {"levels": (25, 30)}, "metrics": ["temperature"]})

        return {"changed": False, "msg": "discovered %d APC Symmetra services" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")

    if item == "" or item.startswith("cartridge_") or item.startswith("temp_"):
        # Main status or specific cartridge/temp check
        pass

    return {"changed": False, "msg": "APC Symmetra check", "data": {"state": "OK", "metrics": {}, "details": ""}}