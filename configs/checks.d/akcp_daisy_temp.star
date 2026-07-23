def main(ctx, params):
    if params.get("_discover"):
        # Gather all temperature sensors from daisy-chained sections
        sections = []
        for base_oid in [
            ".1.3.6.1.4.1.3854.1.2.2.1.19.33.1.2.1",
            ".1.3.6.1.4.1.3854.1.2.2.1.19.33.2.2.1",
            ".1.3.6.1.4.1.3854.1.2.2.1.19.33.3.2.1",
            ".1.3.6.1.4.1.3854.1.2.2.1.19.33.4.2.1",
            ".1.3.6.1.4.1.3854.1.2.2.1.19.33.5.2.1",
            ".1.3.6.1.4.1.3854.1.2.2.1.19.33.6.2.1",
            ".1.3.6.1.4.1.3854.1.2.2.1.19.33.7.2.1",
            ".1.3.6.1.4.1.3854.1.2.2.1.19.33.8.2.1",
        ]:
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), base_oid
            ], mutates=False)
            if res.rc != 0:
                continue
            for line in res.stdout.splitlines():
                # Parse line: "OID.END = STRING: <subport>|<name>|<temp>"
                # We only need: OIDEnd()=port, "1"=subport, "2"=name, "14"=temp
                # Format: .base.oidEnd subport name temp
                parts = line.strip().split()
                if len(parts) < 2:
                    continue
                value = " ".join(parts[1:]).strip()
                # Extract subport, name, temp from "subport|name|temp"
                if "|" not in value:
                    continue
                fields = value.split("|")
                if len(fields) < 3:
                    continue
                subport = fields[0].strip()
                name = fields[1].strip()
                # Ignore sensors that are found by akcp_sensor_temp
                if subport == "-1" or subport == "0":
                    continue
                sections.append({"subport": subport, "name": name})
        out = []
        for item in sections:
            out.append({
                "item": item["name"],
                "params": {"warn": 28.0, "crit": 32.0},
                "metrics": ["temp"]
            })
        return {
            "changed": False,
            "msg": "discovered %d daisy temperature sensors" % len(out),
            "data": {"discovery": out},
        }

    # Normal check mode (single item)
    item = params.get("item", "")
    warn = params.get("warn", 28.0)
    crit = params.get("crit", 32.0)

    # Gather all data from all sections
    temp = None
    for base_oid in [
        ".1.3.6.1.4.1.3854.1.2.2.1.19.33.1.2.1",
        ".1.3.6.1.4.1.3854.1.2.2.1.19.33.2.2.1",
        ".1.3.6.1.4.1.3854.1.2.2.1.19.33.3.2.1",
        ".1.3.6.1.4.1.3854.1.2.2.1.19.33.4.2.1",
        ".1.3.6.1.4.1.3854.1.2.2.1.19.33.5.2.1",
        ".1.3.6.1.4.1.3854.1.2.2.1.19.33.6.2.1",
        ".1.3.6.1.4.1.3854.1.2.2.1.19.33.7.2.1",
        ".1.3.6.1.4.1.3854.1.2.2.1.19.33.8.2.1",
    ]:
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid
        ], mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            value = " ".join(parts[1:]).strip()
            if "|" not in value:
                continue
            fields = value.split("|")
            if len(fields) < 3:
                continue
            subport = fields[0].strip()
            name = fields[1].strip()
            rawtemp = fields[2].strip()
            if subport == "-1" or subport == "0":
                continue
            if name == item:
                temp = float(rawtemp) / 10.0 if rawtemp.isdigit() or (rawtemp.replace(".","").isdigit() and rawtemp.count(".") <= 1) else None
                break
        if temp != None:
            break

    if temp == None:
        return {
            "changed": False,
            "msg": "temperature sensor '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Apply threshold logic
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Temperature: %f C" % temp,
        "data": {
            "state": state,
            "metrics": {"temp": temp},
            "details": "",
        },
    }
