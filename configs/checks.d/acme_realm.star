def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9148.3.2.1.2.4.1"], mutates=False)
        lines = res.stdout.splitlines()
        items = []
        for line in lines:
            # Format: .1.3.6.1.4.1.9148.3.2.1.2.4.1.x.y = STRING: "name,inbound,outbound,total_inbound,total_outbound,state"
            if ".1.3.6.1.4.1.9148.3.2.1.2.4.1" not in line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            value_part = parts[1].strip()
            if not value_part.startswith("STRING:"):
                continue
            # Extract string value
            val_str = value_part[7:].strip().strip('"')
            fields = val_str.split(",")
            if len(fields) < 6:
                continue
            name = fields[0]
            inbound, outbound, total_inbound, total_outbound, state = fields[1], fields[2], fields[3], fields[4], fields[5]
            items.append({"item": name, "params": {}, "metrics": ["inbound", "outbound"]})
        return {"changed": False, "msg": "discovered %d realms" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.9148.3.2.1.2.4.1"], mutates=False)
    lines = res.stdout.splitlines()
    found = False
    for line in lines:
        if ".1.3.6.1.4.1.9148.3.2.1.2.4.1" not in line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        if not value_part.startswith("STRING:"):
            continue
        val_str = value_part[7:].strip().strip('"')
        fields = val_str.split(",")
        if len(fields) < 6:
            continue
        name = fields[0]
        if name != item:
            continue
        found = True
        inbound, outbound, total_inbound, total_outbound, state = fields[1], fields[2], fields[3], fields[4], fields[5]
        map_states = {
            "3": (1, "in service"),
            "4": (1, "contraints violation"),
            "7": (2, "call load reduction"),
        }
        dev_state_num, dev_state_readable = map_states.get(state, (0, "unknown"))
        state_str = "CRIT" if dev_state_num == 2 else ("WARN" if dev_state_num == 1 else "OK")
        msg = "Status: %s, Inbound: %s/%s, Outbound: %s/%s" % (dev_state_readable, inbound, total_inbound, outbound, total_outbound)
        metrics = {
            "inbound": int(inbound),
            "outbound": int(outbound)
        }
        return {"changed": False, "msg": msg,
                "data": {"state": state_str, "metrics": metrics, "details": ""}}
    if not found:
        return {"changed": False, "msg": "realm not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
