_PERF_NAMES = {
    1: "read (bytes/s)",
    2: "write (bytes/s)",
    3: "operations (/s)",
    4: "CIFS read (bytes/s)",
    5: "CIFS write (bytes/s)",
    6: "CIFS operations (/s)",
    7: "NFS read (bytes/s)",
    8: "NFS write (bytes/s)",
    9: "NFS operations (/s)",
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.12962.1.1.2.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            val_part = parts[1].strip()
            if not val_part.startswith("INTEGER:"):
                continue
            value = val_part.split(":", 1)[1].strip()
            index = oid_val.rsplit(".", 1)[-1]
            name = _PERF_NAMES.get(int(index), "unknown " + index)
            items.append({
                "item": index + ": " + name,
                "params": {},
                "metrics": ["rate"]
            })

        return {
            "changed": False,
            "msg": "discovered %d performance counters" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    if item == "" or ":" not in item:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    index = item.split(":", 1)[0].strip()
    
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.12962.1.1.2.1.1." + index
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for item " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    output = res.stdout.strip()
    if " = INTEGER:" not in output:
        return {
            "changed": False,
            "msg": "unexpected SNMP response for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = output.split(" = INTEGER:", 1)[1].strip()
    if not value_str:
        return {
            "changed": False,
            "msg": "empty rate value for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if not value_str.lstrip("-").isdigit():
        return {
            "changed": False,
            "msg": "cannot parse rate value: " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    rate = int(value_str)

    state = "OK"
    return {
        "changed": False,
        "msg": "Current rate: %d/s" % rate,
        "data": {
            "state": state,
            "metrics": {"rate": rate},
            "details": ""
        }
    }
