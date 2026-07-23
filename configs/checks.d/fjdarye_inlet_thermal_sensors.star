# Constants defined at module top level
FJDARYE_SUPPORTED_DEVICES = [
    ".1.3.6.1.4.1.211.1.21.1.60",   # fjdarye60
    ".1.3.6.1.4.1.211.1.21.1.150",  # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153",  # fjdarye600
]

FJDARYE_ITEM_STATUS = {
    "1": {"state": "OK", "summary": "Normal"},
    "2": {"state": "CRIT", "summary": "Alarm"},
    "3": {"state": "WARN", "summary": "Warning"},
    "4": {"state": "CRIT", "summary": "Invalid"},
    "5": {"state": "CRIT", "summary": "Maintenance"},
    "6": {"state": "CRIT", "summary": "Undefined"},
}


def main(ctx, params):
    # Discovery mode: enumerate all valid thermal sensors
    if params.get("_discover"):
        devices = []
        for base in FJDARYE_SUPPORTED_DEVICES:
            # snmpwalk base OID: .2.10.2.1 (FJDARYE thermal sensors section)
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"),
                base + ".2.10.2.1"
            ], mutates=False)
            if res.rc != 0:
                continue

            # Parse snmpwalk output lines: "<oid>.<index> = INTEGER: <status>"
            for line in res.stdout.splitlines():
                # Split into OID and value part
                parts = line.strip().split(" = ")
                if len(parts) != 2:
                    continue
                oid_part = parts[0].strip()
                value_part = parts[1].strip()

                # Extract index from OID: base.2.10.2.1.<index>
                suffix = oid_part.rfind(".")
                if suffix == -1:
                    continue
                index_str = oid_part[suffix+1:]

                # Extract integer status value
                type_value = value_part.split(": ")
                if len(type_value) != 2:
                    continue
                status = type_value[1].strip()

                # Only include if status != "4" (Invalid)
                if status != "4":
                    devices.append({
                        "item": index_str,
                        "params": {},
                        "metrics": []
                    })

        return {
            "changed": False,
            "msg": "discovered %d thermal sensors" % len(devices),
            "data": {"discovery": devices}
        }

    # Check mode: examine one specific sensor item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Walk all supported device thermal sensor sections
    for base in FJDARYE_SUPPORTED_DEVICES:
        # Use snmpget for the specific item: base.2.10.2.1.<item>.3 (status OID)
        status_oid = base + ".2.10.2.1." + item + ".3"
        res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), status_oid
        ], mutates=False)
        if res.rc != 0:
            continue

        # Parse output: "<oid> = INTEGER: <value>"
        line = res.stdout.strip()
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        type_value = value_part.split(": ")
        if len(type_value) != 2:
            continue
        status = type_value[1].strip()

        # Map status to state and summary
        entry = FJDARYE_ITEM_STATUS.get(status, {"state": "UNKNOWN", "summary": "Unknown"})
        summary = entry["summary"]
        state = entry["state"]

        return {
            "changed": False,
            "msg": "Sensor %s: %s" % (item, summary),
            "data": {"state": state, "metrics": {}, "details": ""}
        }

    # Item not found on any device
    return {
        "changed": False,
        "msg": "thermal sensor not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
