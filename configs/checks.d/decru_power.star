def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.12962.1.2.6.1.2"
        ], mutates=False)
        discovery = []
        for line in res.stdout.splitlines():
            fields = line.strip().split()
            if len(fields) >= 2:
                item = fields[1].split(":", 1)[-1].strip()
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    # Fetch both columns: .1.3.6.1.4.1.12962.1.2.6.1.2 (powerIndex) and .3 (powerStatus)
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.12962.1.2.6.1"
    ], mutates=False)

    lines = res.stdout.splitlines()
    index_to_status = {}

    # First pass: collect index -> status mapping
    for line in lines:
        if len(line.split()) < 2:
            continue
        parts = line.strip().split()
        oid_str = parts[0]
        val_str = parts[1].split(":", 1)[-1].strip()

        if oid_str.endswith(".2"):
            # Extract index number
            suffix = oid_str.rsplit(".", 1)[-1]
            if suffix.isdigit():
                idx = int(suffix)
                index_to_status[idx] = {"item": val_str, "status": None}
        elif oid_str.endswith(".3"):
            suffix = oid_str.rsplit(".", 1)[-1]
            if suffix.isdigit():
                idx = int(suffix)
                if idx in index_to_status:
                    index_to_status[idx]["status"] = val_str

    # Look for the requested item
    for idx in index_to_status:
        data = index_to_status[idx]
        if data["item"] == item:
            if data["status"] == None:
                return {
                    "changed": False,
                    "msg": "power supply not found",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            if data["status"] == "1":
                return {
                    "changed": False,
                    "msg": "power supply ok",
                    "data": {"state": "OK", "metrics": {}, "details": ""}
                }
            return {
                "changed": False,
                "msg": "power supply in state %s" % data["status"],
                "data": {"state": "CRIT", "metrics": {}, "details": ""}
            }

    return {
        "changed": False,
        "msg": "power supply not found",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }