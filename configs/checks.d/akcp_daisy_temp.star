def main(ctx, params):
    if params.get("_discover"):
        items = []
        for chain in range(1, 9):
            base = ".1.3.6.1.4.1.3854.1.2.2.1.19.33." + str(chain) + ".2.1"
            res = ctx.run([
                "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
                base
            ], mutates=False)
            if res.rc != 0:
                continue
            for line in res.stdout.splitlines():
                if len(line) == 0:
                    continue
                eq_idx = line.find("=")
                if eq_idx == -1:
                    continue
                oid_part = line[:eq_idx].strip()
                value_part = line[eq_idx+1:].strip()
                oid_parts = oid_part.split(".")
                if len(oid_parts) < 15:
                    continue
                subport = oid_parts[-2]
                if subport in ["-1", "0"]:
                    continue
                if value_part.startswith('"') and value_part.endswith('"'):
                    name = value_part[1:-1]
                elif value_part.startswith('STRING: "'):
                    name = value_part[8:-1]
                    if name.endswith('"'):
                        name = name[:-1]
                else:
                    continue
                oid_end = oid_parts[-1]
                temp_oid = base + "." + oid_end + ".14"
                temp_res = ctx.run([
                    "snmpget", "-On", "-v2c", "-c", "public", "localhost",
                    temp_oid
                ], mutates=False)
                if temp_res.rc != 0:
                    continue
                temp_line = temp_res.stdout.strip()
                if len(temp_line) == 0:
                    continue
                temp_eq_idx = temp_line.find("=")
                if temp_eq_idx == -1:
                    continue
                temp_val_str = temp_line[temp_eq_idx+1:].strip()
                rawtemp = None
                if temp_val_str.startswith('INTEGER: '):
                    rawtemp_str = temp_val_str[9:].strip()
                    if len(rawtemp_str) > 0 and rawtemp_str.isdigit() or (rawtemp_str.startswith('-') and rawtemp_str[1:].isdigit()):
                        rawtemp = int(rawtemp_str)
                elif temp_val_str.isdigit() or (temp_val_str.startswith('-') and temp_val_str[1:].isdigit()):
                    rawtemp = int(temp_val_str)
                if rawtemp != None:
                    temp = float(rawtemp) / 10.0
                    items.append({
                        "item": name,
                        "params": {"levels": (28.0, 32.0)},
                        "metrics": ["temperature"]
                    })
        return {
            "changed": False,
            "msg": "discovered %d daisy temperature sensors" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    warn = params.get("levels", (28.0, 32.0))
    warn_high = 28.0
    crit_high = 32.0
    if type(warn) == "list" or type(warn) == "tuple":
        warn_high = warn[0]
        crit_high = warn[1]

    temp = None
    for chain in range(1, 9):
        base = ".1.3.6.1.4.1.3854.1.2.2.1.19.33." + str(chain) + ".2.1"
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            base
        ], mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            if len(line) == 0:
                continue
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            value_part = line[eq_idx+1:].strip()
            oid_parts = oid_part.split(".")
            if len(oid_parts) < 15:
                continue
            subport = oid_parts[-2]
            if subport in ["-1", "0"]:
                continue
            name = ""
            if value_part.startswith('"') and value_part.endswith('"'):
                name = value_part[1:-1]
            elif value_part.startswith('STRING: "'):
                name = value_part[8:]
                if len(name) > 0 and name.endswith('"'):
                    name = name[:-1]
            else:
                continue
            if name == item:
                oid_end = oid_parts[-1]
                temp_oid = base + "." + oid_end + ".14"
                temp_res = ctx.run([
                    "snmpget", "-On", "-v2c", "-c", "public", "localhost",
                    temp_oid
                ], mutates=False)
                if temp_res.rc != 0:
                    continue
                temp_line = temp_res.stdout.strip()
                if len(temp_line) == 0:
                    continue
                temp_eq_idx = temp_line.find("=")
                if temp_eq_idx == -1:
                    continue
                temp_val_str = temp_line[temp_eq_idx+1:].strip()
                rawtemp = None
                if temp_val_str.startswith('INTEGER: '):
                    rawtemp_str = temp_val_str[9:].strip()
                    if len(rawtemp_str) > 0 and rawtemp_str.isdigit() or (rawtemp_str.startswith('-') and rawtemp_str[1:].isdigit()):
                        rawtemp = int(rawtemp_str)
                elif temp_val_str.isdigit() or (temp_val_str.startswith('-') and temp_val_str[1:].isdigit()):
                    rawtemp = int(temp_val_str)
                if rawtemp != None:
                    temp = float(rawtemp) / 10.0
                break
        if temp != None:
            break

    if temp == None:
        return {
            "changed": False,
            "msg": "temperature sensor '%s' not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    state = "OK"
    if temp >= crit_high:
        state = "CRIT"
    elif temp >= warn_high:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Temperature: %.1f C" % temp,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }
