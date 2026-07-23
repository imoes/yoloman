def main(ctx, params):
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.2021.13.15.1.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), base_oid], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        disks = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 2)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            value_str = value_part.split(": ", 1)[1].strip() if ": " in value_part else ""
            
            rel_oid = oid_part[len(base_oid):].strip()
            if not rel_oid.startswith("."):
                continue
            rel_oid_parts = rel_oid[1:].split(".")
            if len(rel_oid_parts) != 2:
                continue
            idx_str, sub_oid_num = rel_oid_parts
            idx = int(idx_str) if idx_str.isdigit() else -1
            sub = int(sub_oid_num) if sub_oid_num.isdigit() else -1
            
            if sub == 2 and value_str:
                if idx >= 0:
                    disks[idx] = {"item": value_str, "disk_index": ""}
            elif sub == 1:
                if idx >= 0 and idx in disks:
                    disks[idx]["disk_index"] = value_str
        
        discovery = []
        for d in disks.values():
            if d["item"]:
                discovery.append({"item": d["item"], "params": {}, "metrics": ["read_throughput", "write_throughput", "read_ios", "write_ios"]})
        
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not item:
        fail("item is required for check mode")

    base_oid = ".1.3.6.1.4.1.2021.13.15.1.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), base_oid], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    idx_str = ""
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 2)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        value_str = value_part.split(": ", 1)[1].strip() if ": " in value_part else ""
        rel_oid = oid_part[len(base_oid):].strip()
        if not rel_oid.startswith("."):
            continue
        rel_oid_parts = rel_oid[1:].split(".")
        if len(rel_oid_parts) != 2:
            continue
        i_str, sub_str = rel_oid_parts
        i = int(i_str) if i_str.isdigit() else -1
        sub = int(sub_str) if sub_str.isdigit() else -1
        
        if sub == 2 and value_str == item:
            if i >= 0:
                idx_str = str(i)
                break

    if not idx_str:
        return {
            "changed": False,
            "msg": "disk item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    oids = [
        base_oid + "." + idx_str + ".1",
        base_oid + "." + idx_str + ".2",
        base_oid + "." + idx_str + ".3",
        base_oid + "." + idx_str + ".4",
        base_oid + "." + idx_str + ".5",
        base_oid + "." + idx_str + ".6",
    ]
    get_out = ""
    for oid in oids:
        gres = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                        "-On", params.get("host", "localhost"), oid], mutates=False)
        if gres.rc == 0:
            get_out += gres.stdout.strip() + "\n"
        else:
            return {
                "changed": False,
                "msg": "SNMP get failed for " + oid + ": " + gres.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    values = {}
    for line in get_out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 2)
        if len(parts) != 2:
            continue
        value_part = parts[1]
        if ": " in value_part:
            value_str = value_part.split(": ", 1)[1].strip()
        else:
            value_str = ""
        oid_part = parts[0][len(base_oid):].strip()
        if not oid_part.startswith("."):
            continue
        rel = oid_part[1:].split(".")
        if len(rel) != 1:
            continue
        sub = int(rel[0]) if rel[0].isdigit() else -1
        
        if sub == 1:
            values["disk_index"] = value_str
        elif sub == 3:
            values["read_throughput_raw"] = value_str
        elif sub == 4:
            values["write_throughput_raw"] = value_str
        elif sub == 5:
            values["read_ios_raw"] = value_str
        elif sub == 6:
            values["write_ios_raw"] = value_str

    required = ["read_ios_raw", "write_ios_raw", "read_throughput_raw", "write_throughput_raw"]
    all_numeric = True
    for k in required:
        if k not in values:
            all_numeric = False
            break
        if not values[k].isdigit():
            all_numeric = False
            break

    if not all_numeric:
        return {
            "changed": False,
            "msg": "disk data incomplete for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    index = values.get("disk_index", "")
    summary = "[%s]" % index if index else ""
    disk_data = {
        "read_ios": 0.0,
        "write_ios": 0.0,
        "read_throughput": 0.0,
        "write_throughput": 0.0,
    }
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": disk_data,
            "details": "",
        },
    }