# ===== Starlark translation of Checkmk nimble_latency check =====
# Reads latency data via SNMP for a single volume, computes percentage
# of I/O operations in latency ranges >= range_reference, and compares
# against warn/crit levels.

def main(ctx, params):
    # Discovery mode: enumerate volume items via SNMP
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.37447.1.2.1.3"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        items = []
        lines = res.stdout.splitlines()
        for line in lines:
            parts = line.strip().split()
            if len(parts) >= 2:
                # Extract volume name from last column of value (after =)
                val = parts[1]
                # The value is a string like "VOL1", strip quotes if present
                vol = val.strip('"').strip("'")
                if vol:
                    items.append({
                        "item": vol,
                        "params": {
                            "range_reference": "20",
                            "read": [10.0, 20.0],
                            "write": [10.0, 20.0]
                        },
                        "metrics": ["nimble_read_latency_20", "nimble_read_latency_50", "nimble_read_latency_100"]
                    })
        return {
            "changed": False,
            "msg": "discovered %d volumes" % len(items),
            "data": {"discovery": items}
        }

    # Check mode for one volume item
    item = params.get("item", "")
    if item == "":
        fail("item is required for check mode")

    # Fetch latency SNMP data
    # OIDs: base + offsets for read (13..26) and write (39..52)
    base_oid = ".1.3.6.1.4.1.37447.1.2.1."
    read_oids = [str(base_oid + o) for o in ["13", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", "31", "32", "33", "34"]]
    write_oids = [str(base_oid + o) for o in ["39", "40", "41", "42", "43", "44", "45", "46", "47", "48", "49", "50", "51", "52", "53"]]

    # Gather both read and write data
    read_values = []
    write_values = []
    for oid_list, val_list in [(read_oids, read_values), (write_oids, write_values)]:
        for oid in oid_list:
            res = ctx.run([
                "snmpget",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                oid
            ], mutates=False)
            if res.rc != 0:
                fail("SNMP get failed for " + oid + ": " + res.stderr)
            # Parse "OID = STRING: value"
            line = res.stdout.strip()
            if "=" in line:
                parts = line.split("=", 1)
                if len(parts) == 2:
                    v = parts[1].strip()
                    # Extract numeric value from strings like "INTEGER: 123" or just "123"
                    for prefix in ["INTEGER: ", "Counter32: ", "Gauge32: "]:
                        if v.startswith(prefix):
                            v = v[len(prefix):].strip()
                    # Guard instead of try/except
                    if v.isdigit():
                        val_list.append(int(v))
                    else:
                        val_list.append(0)
            else:
                val_list.append(0)

    # Range keys in order (total is first, then ranges)
    range_keys = [
        ("total", "Total"),
        ("0.1", "0-0.1 ms"),
        ("0.2", "0.1-0.2 ms"),
        ("0.5", "0.2-0.5 ms"),
        ("1", "0.5-1.0 ms"),
        ("2", "1-2 ms"),
        ("5", "2-5 ms"),
        ("10", "5-10 ms"),
        ("20", "10-20 ms"),
        ("50", "20-50 ms"),
        ("100", "50-100 ms"),
        ("200", "100-200 ms"),
        ("500", "200-500 ms"),
        ("1000", "500+ ms"),
    ]

    # Build read data section (14 values: total + 13 ranges)
    read_data = build_latency_section(read_values, range_keys)
    write_data = build_latency_section(write_values, range_keys)

    # Decide type based on item suffix if needed; default to reads
    ty = "read"
    if item.endswith("_write") or params.get("type") == "write":
        ty = "write"

    # Choose data
    data = read_data
    if ty == "write":
        data = write_data

    # Check logic
    if not data.get("total"):
        return {
            "changed": False,
            "msg": "no data for volume " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    total_value = data.get("total", 0)
    if total_value == 0:
        return {
            "changed": False,
            "msg": "No current " + ty + " operations",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    range_reference = float(params.get("range_reference", "20"))
    warn_pct = float(params.get(ty, [10.0, 20.0])[0])
    crit_pct = float(params.get(ty, [10.0, 20.0])[1])

    running_total_percent = 0.0
    metrics = {}
    details_parts = []
    first = True
    for key in data.get("ranges", {}).keys():
        title, value = data["ranges"][key]
        metric_name = "nimble_" + ty + "_latency_" + key.replace(".", "")
        percent_value = (float(value) / float(total_value)) * 100.0
        metrics[metric_name] = percent_value

        if float(key) >= range_reference:
            running_total_percent += percent_value

        if not first:
            details_parts.append("\n")
        details_parts.append(title + ": " + str(value) + " ops (" + "%f%%" % percent_value + ")")
        first = False

    # Compute aggregate state for the tail (>= range_reference)
    if running_total_percent >= crit_pct:
        state = "CRIT"
    elif running_total_percent >= warn_pct:
        state = "WARN"
    else:
        state = "OK"

    # Build summary
    ref_title = ""
    ref_val = data["ranges"].get(str(range_reference), ("", ""))
    if ref_val and ref_val[0]:
        ref_title = ref_val[0]
    else:
        # fallback: map to closest range
        ref_title = "%s ms" % str(range_reference)

    summary = "%s operations at or above %s: %f%%" % (ty, ref_title, running_total_percent)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "".join(details_parts)
        }
    }


def build_latency_section(values, range_keys):
    # values[0] is total, values[1:] are 13 ranges
    if not values or len(values) < len(range_keys):
        return {}
    data = {}
    # total
    if values[0] >= 0 if type(values[0]) == "int" else False:
        data["total"] = int(values[0])
    else:
        data["total"] = 0

    # ranges (skip total)
    ranges = {}
    for i in range(1, len(range_keys)):
        key, title = range_keys[i]
        v = values[i]
        if v >= 0 if type(v) == "int" else False:
            data_val = int(v)
        else:
            data_val = 0
        ranges[key] = (title, data_val)
    if ranges:
        data["ranges"] = ranges
    return data