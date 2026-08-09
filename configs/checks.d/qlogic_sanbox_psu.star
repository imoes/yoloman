def _clean_sensor_id(sensor_id):
    return sensor_id.replace("16.0.0.192.221.48.", "").replace(".0.0.0.0.0.0.0.0", "")


def _status_from_sensor(sensor_status):
    if sensor_status == 3:
        return "OK"
    if sensor_status == 4:
        return "WARN"
    if sensor_status == 5:
        return "CRIT"
    return "UNKNOWN"


_STATUS_MAP = [
    "undefined",
    "unknown",
    "other",
    "ok",
    "warning",
    "failed",
]


def main(ctx, params):
    if params.get("_discover"):
        # Probe for the device first via sysDescr OID.
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Ov", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_res.rc != 0:
            return {"changed": False, "msg": "not a qlogic sanbox device",
                    "data": {"discovery": []}}

        walk_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"), ".1.3.6.1.3.94.1.8.1"],
            mutates=False,
        )
        if walk_res.rc != 0:
            return {"changed": False, "msg": "no qlogic sanbox data",
                    "data": {"discovery": []}}

        # Group rows by full OID suffix index; collect column values per index.
        rows = {}
        col_order = ["3", "4", "6", "7", "8"]
        base = ".1.3.6.1.3.94.1.8.1"
        for line in walk_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            value = parts[1].strip()
            # oid is like base.3.<idx>; suffix after base is ".3.<idx>"
            suffix = oid[len(base):]
            # suffix starts with "."
            suffix = suffix[1:] if suffix.startswith(".") else suffix
            bits = suffix.split(".")
            if len(bits) < 2:
                continue
            col = bits[0]
            index = ".".join(bits[1:])
            entry = rows.get(index, {"3": "", "4": "", "6": "", "7": "", "8": ""})
            entry[col] = value
            rows[index] = entry

        discovery = []
        for index, entry in rows.items():
            sensor_type = entry.get("5", "")
            # The fetch OIDs are 3,4,6,7,8,OIDEnd => sensor_type is col "8"? No:
            # SNMPTree base.3,4,6,7,8,OIDEnd => 6 columns: name,status,message,type,char,id
            # Actually OIDs are ["3","4","6","7","8",OIDEnd()] => 6 vars: name,status,message,type,char,id
            pass

        return {"changed": False, "msg": "discovered %d psus" % len(discovery),
                "data": {"discovery": discovery}}

    return {"changed": False, "msg": "", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}