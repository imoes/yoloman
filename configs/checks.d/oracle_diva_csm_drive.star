def main(ctx, params):
    # Discovery mode: enumerate all drives
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.110901.1.2.2.1.1"

        # Fetch drive status: .1.3.6.1.4.1.110901.1.2.2.1.1.8 (status)
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        drive_items = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Parse: .1.3.6.1.4.1.110901.1.2.2.1.1.8.1.1.x = INTEGER: 1
            if ".8.1.1." in line:
                parts = line.split(" = ")
                if len(parts) != 2:
                    continue
                oid_part = parts[0]
                value_part = parts[1]
                # Extract x from .8.1.1.x (last component)
                fields = oid_part.split(".")
                if len(fields) < 11:
                    continue
                drive_id = fields[-1]
                # Extract integer value
                status_str_raw = value_part.split(": ")
                if len(status_str_raw) < 2:
                    status_int = 3
                else:
                    status_val = status_str_raw[1].strip()
                    status_int = int(status_val) if status_val.isdigit() else 3
                # Convert status to string
                if status_int == 1:
                    status_display = "online"
                elif status_int == 2:
                    status_display = "offline"
                elif status_int == 3:
                    status_display = "unknown"
                else:
                    status_display = "unexpected state"
                # Build item name
                item_name = "Drive " + drive_id
                drive_items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d drives" % len(drive_items),
            "data": {"discovery": drive_items}
        }

    # Check mode: single item
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.110901.1.2.2.1.1"
    item = params.get("item", "")

    # Extract drive ID from item name "Drive X"
    if item.startswith("Drive "):
        drive_id_str = item[6:].strip()
    else:
        drive_id_str = ""

    # Perform snmpget for the specific drive status OID: .8.1.1.<drive_id>
    status_oid = base_oid + ".8.1.1." + drive_id_str
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, status_oid], mutates=False)
    output = res.stdout.strip()

    # Parse the value
    status_int = 3  # unknown default
    if output:
        parts = output.split(" = ")
        if len(parts) == 2:
            value_str = parts[1]
            if ": " in value_str:
                status_parts = value_str.split(": ")
                if len(status_parts) >= 2:
                    status_val = status_parts[1].strip()
                    status_int = int(status_val) if status_val.isdigit() else 3

    # Map status integer to state and summary
    if status_int == 1:
        state_str = "OK"
        summary = "online"
    elif status_int == 2:
        state_str = "CRIT"
        summary = "offline"
    elif status_int == 3:
        state_str = "WARN"
        summary = "unknown"
    else:
        state_str = "UNKNOWN"
        summary = "unexpected state"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }