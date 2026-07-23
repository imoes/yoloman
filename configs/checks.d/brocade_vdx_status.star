def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    res = ctx.run([
        "snmpget", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.1588.2.1.1.1.1.6.0",
        ".1.3.6.1.4.1.1588.2.1.1.1.1.7.0"
    ], mutates=False)

    lines = res.stdout.strip().split("\n") if res.stdout.strip() else []

    firmware = ""
    status = None

    for line in lines:
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()

        if oid == ".1.3.6.1.4.1.1588.2.1.1.1.1.6.0":
            v = value
            if v.startswith("STRING: "):
                v = v[8:]
            if v.startswith('"') and v.endswith('"'):
                v = v[1:-1]
            firmware = v
        elif oid == ".1.3.6.1.4.1.1588.2.1.1.1.1.7.0":
            v = value
            for prefix in ("INTEGER: ", "Gauge32: "):
                if v.startswith(prefix):
                    v = v[len(prefix):]
            if v.isdigit() or (v.startswith("-") and v[1:].isdigit()):
                status = int(v)
            else:
                status = None

    status_map = {1: "OK", 2: "CRIT", 3: "WARN", 4: "CRIT"}
    status_readable = {1: "online", 2: "offline", 3: "testing", 4: "faulty"}

    if status == None or firmware == "":
        return {
            "changed": False,
            "msg": "missing SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state_str = status_map.get(status, "UNKNOWN")
    readable = status_readable.get(status, "unknown")

    return {
        "changed": False,
        "msg": "State: %s, Firmware: %s" % (readable, firmware),
        "data": {"state": state_str, "metrics": {}, "details": ""}
    }
