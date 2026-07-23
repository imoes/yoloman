def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.45.1.6.3.3.1.1.10.6"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        discovery = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            oid_tokens = oid_part.split(".")
            if len(oid_tokens) == 0:
                continue
            last_token = oid_tokens[-1]
            if not last_token.isdigit():
                continue
            index = int(last_token)
            if not value_part.startswith("INTEGER: "):
                continue
            status = value_part.split("INTEGER: ")[1].strip()
            item = str(index)
            discovery.append({"item": item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.45.1.6.3.3.1.1.10.6." + item
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "fan item %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    line = res.stdout.strip()
    if not line:
        return {
            "changed": False,
            "msg": "empty response for fan %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    parts = line.split(" = ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "malformed snmpget output for fan %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status_str = parts[1].strip()
    if not status_str.startswith("INTEGER: "):
        return {
            "changed": False,
            "msg": "unexpected response format for fan %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    fan_status = status_str.split("INTEGER: ")[1].strip()

    STATE_MAP = {
        "1": ("Other", "UNKNOWN"),
        "2": ("Not available", "UNKNOWN"),
        "3": ("Removed", "OK"),
        "4": ("Disabled", "OK"),
        "5": ("Normal", "OK"),
        "6": ("Reset in Progress", "WARN"),
        "7": ("Testing", "WARN"),
        "8": ("Warning", "WARN"),
        "9": ("Non fatal error", "WARN"),
        "10": ("Fatal error", "CRIT"),
        "11": ("Not configured", "WARN"),
        "12": ("Obsoleted", "OK"),
    }

    text, state = STATE_MAP.get(fan_status, ("Unknown fan status: %s" % fan_status, "UNKNOWN"))
    return {
        "changed": False,
        "msg": text,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
