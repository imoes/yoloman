def main(ctx, params):
    if params.get("_discover"):
        discovered = []
        tables = ["19", "38", "66", "67"]
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        for table in tables:
            base_oid = ".1.3.6.1.4.1.28507." + table + ".1.6.1.1"
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
            if res.rc != 0:
                continue
            lines = res.stdout.splitlines()
            for line in lines:
                parts = line.strip().split()
                if len(parts) < 3:
                    continue
                oid_part = parts[0].strip()
                if not oid_part.endswith(".2"):
                    continue
                oid_parts = oid_part.split(".")
                if len(oid_parts) < 2:
                    continue
                idx_str = oid_parts[-2]
                if not idx_str.isdigit():
                    continue
                index = int(idx_str)
                # Extract value after " = "
                val_str = ""
                eq_pos = line.find(" = ")
                if eq_pos >= 0:
                    val_str = line[eq_pos + 3:].strip()
                else:
                    continue
                # Strip type prefix if present
                for t in ["INTEGER:", "Gauge32:", "Integer32:", "Counter32:", "Counter64:"]:
                    if val_str.startswith(t):
                        val_str = val_str[len(t):].strip()
                        break
                # Parse as integer
                if not val_str.replace("-", "").isdigit():
                    continue
                raw = int(val_str)
                temp = float(raw) / 10.0
                if temp != -999.9:
                    item = "Sensor " + str(index)
                    discovered.append({
                        "item": item,
                        "params": {"levels": (35.0, 40.0)},
                        "metrics": ["temp"]
                    })
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode
    item = params.get("item", "")
    if item == None:
        item = ""
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Extract numeric index from "Sensor X"
    if not item.startswith("Sensor "):
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    index_str = item[7:]  # after "Sensor "
    if not index_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid sensor index",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    index = int(index_str)

    # Walk all tables to find this sensor
    tables = ["19", "38", "66", "67"]
    temp_val = None

    for table in tables:
        base_oid = ".1.3.6.1.4.1.28507." + table + ".1.6.1.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            continue
        lines = res.stdout.splitlines()
        for line in lines:
            parts = line.strip().split()
            if len(parts) < 1:
                continue
            oid_part = parts[0].strip()
            oid_parts = oid_part.split(".")
            if len(oid_parts) < 2:
                continue
            idx_str = oid_parts[-2]
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            if idx == index and oid_part.endswith(".2"):
                val_str = ""
                eq_pos = line.find(" = ")
                if eq_pos >= 0:
                    val_str = line[eq_pos + 3:].strip()
                else:
                    continue
                for t in ["INTEGER:", "Gauge32:", "Integer32:", "Counter32:", "Counter64:"]:
                    if val_str.startswith(t):
                        val_str = val_str[len(t):].strip()
                        break
                if not val_str.replace("-", "").isdigit():
                    continue
                raw = int(val_str)
                temp_val = float(raw) / 10.0
                break
        if temp_val != None:
            break

    if temp_val == None:
        return {
            "changed": False,
            "msg": "sensor %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply thresholds from params
    warn, crit = params.get("levels", (35.0, 40.0))
    state = "CRIT" if temp_val >= crit else ("WARN" if temp_val >= warn else "OK")
    return {
        "changed": False,
        "msg": "Temperature: %f C" % temp_val,
        "data": {
            "state": state,
            "metrics": {"temp": temp_val},
            "details": ""
        }
    }