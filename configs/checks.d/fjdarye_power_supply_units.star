FJDARYE_POWER_SUPPLY_UNIT = ".1.3.6.1.4.1.211.1.21.1.60"

FJDARYE_ITEM_STATUS = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        sys_descr = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, ".1.3.6.1.2.1.1.2.0",
        ], mutates=False)
        if sys_descr.rc != 0 or sys_descr.stdout == "":
            return {"changed": False, "msg": "not installed", "data": {"discovery": []}}

        if sys_descr.stdout.strip() != FJDARYE_POWER_SUPPLY_UNIT:
            return {"changed": False, "msg": "not a FJDARYE device", "data": {"discovery": []}}

        walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, "1.3.6.1.4.1.211.1.21.1.60.2.9.2.1",
        ], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "walk failed", "data": {"discovery": []}}

        discovery = []
        index_to_status = {}
        for line in walk.stdout.splitlines():
            parts = line.strip().split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            value = parts[1]
            col = oid.split(".")[-2]
            idx = oid.split(".")[-1]
            if col == "1":
                index_to_status[idx] = {"index": value}
            elif col == "3":
                if idx in index_to_status:
                    index_to_status[idx]["status"] = value

        for idx, data in index_to_status.items():
            status = data.get("status", "")
            if status == "4":
                continue
            discovery.append({
                "item": idx,
                "params": {},
                "metrics": [],
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

        item = params.get("item", "")

        host = params.get("host", "localhost")
        community = params.get("community", "public")

        walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, "1.3.6.1.4.1.211.1.21.1.60.2.9.2.1.3." + item,
        ], mutates=False)
        if walk.rc != 0 or walk.stdout.strip() == "":
            return {
                "changed": False,
                "msg": "no such item: " + str(item),
                "data": {
                    "state": "UNKNOWN",
                    "metrics": {},
                    "details": "no such item: " + str(item),
                },
            }

        value = walk.stdout.strip().split(" ", 1)
        status = value[1] if len(value) == 2 else ""

        entry = FJDARYE_ITEM_STATUS.get(status)
        if entry == None:
            state = "UNKNOWN"
            summary = "Unknown"
        else:
            state = entry[0]
            summary = entry[1]

        return {
            "changed": False,
            "msg": summary,
            "data": {
                "state": state,
                "metrics": {},
                "details": "Status: " + summary,
            },
        }