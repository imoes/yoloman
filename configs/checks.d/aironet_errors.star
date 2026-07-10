def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.9.9.272.1.2.1.1.1"
        ], mutates=False)
        lines = res.stdout.splitlines()
        found_indices = {}
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            # Look for counter OID: base.2.<index>
            # In numeric OID, we expect something like "... .2.1 = ..."
            idx_part = oid.rsplit(".2.", 1)
            if len(idx_part) == 2:
                idx_str = idx_part[1]
                if idx_str.isdigit():
                    value_str = parts[1].strip()
                    if value_str.startswith("INTEGER: "):
                        value = int(value_str[11:])
                    elif value_str.startswith("INTEGER:"):
                        value = int(value_str[10:])
                    else:
                        # Try direct parse
                        value = int(value_str)
                    found_indices[idx_str] = value
        items = []
        for idx, value in found_indices.items():
            items.append({
                "item": idx,
                "params": {},
                "metrics": ["errors"]
            })
        return {
            "changed": False,
            "msg": "discovered %d radios" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    oid = ".1.3.6.1.4.1.9.9.272.1.2.1.1.1.2." + item
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", oid], mutates=False)
    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return {
            "changed": False,
            "msg": "no data for radio " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    line = lines[0]
    value_str = ""
    if " = " in line:
        value_str = line.split(" = ", 1)[1].strip()
    else:
        return {
            "changed": False,
            "msg": "malformed output for radio " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if value_str.startswith("INTEGER: "):
        current_errors = int(value_str[11:])
    elif value_str.startswith("INTEGER:"):
        current_errors = int(value_str[10:])
    else:
        current_errors = int(value_str)

    # Approximate rate as absolute counter (due to no rate cache in Starlark)
    # Levels: WARN >= 1.0, CRIT >= 10.0 (fixed levels from Checkmk plugin)
    state = "OK"
    if current_errors >= 10.0:
        state = "CRIT"
    elif current_errors >= 1.0:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Errors/s: " + str(current_errors),
        "data": {
            "state": state,
            "metrics": {"errors": current_errors},
            "details": ""
        }
    }
