def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.14823.2.2.1.1.3.2"], mutates=False)
        if res.rc == 0 and res.stdout.strip():
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": ["connections"]}]}}
        else:
            return {"changed": False, "msg": "no aruba_clients data available",
                    "data": {"discovery": []}}

    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.14823.2.2.1.1.3.2"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to retrieve SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    line = res.stdout.strip()
    parts = line.split("=", 1)
    if len(parts) != 2:
        return {"changed": False, "msg": "unexpected SNMP output format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_part = parts[1].strip()
    if ":" in value_part:
        value_part = value_part.split(":", 1)[1].strip()
    # Check if value_part is a valid integer string manually
    stripped = value_part.strip()
    is_int = True
    if stripped == "":
        is_int = False
    else:
        for i in range(len(stripped)):
            c = stripped[i]
            if c < "0" or c > "9":
                if i == 0 and c == "-":
                    continue
                is_int = False
                break
    if is_int == False:
        return {"changed": False, "msg": "invalid client count value: " + value_part,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    connected_clients = int(stripped)
    return {"changed": False, "msg": "Connections: %d" % connected_clients,
            "data": {"state": "OK", "metrics": {"connections": connected_clients}, "details": ""}}
