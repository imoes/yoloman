def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real Avaya 45xx chassis first by checking sysObjectID.
        sys_oid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), params.get("host", "localhost"), "-Oqv", ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid.rc != 0 or sys_oid.skipped:
            return {"changed": False, "msg": "no SNMP device or not an Avaya 45xx chassis", "data": {"discovery": []}}
        if ".1.3.6.1.4.1.45.3" not in sys_oid.stdout:
            return {"changed": False, "msg": "not an Avaya 45xx chassis", "data": {"discovery": []}}
        # Walk the fan status column.
        walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), params.get("host", "localhost"), "-Oqn", "-OQ", ".1.3.6.1.4.1.45.1.6.3.3.1.1.10.6"], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "failed to walk avaya fan status", "data": {"discovery": []}}
        discovery = []
        for line in walk.stdout.splitlines():
            oid_end = line.find(" ")
            if oid_end < 0:
                continue
            # index is the OID suffix after the column base "...10.6."
            index = line[:oid_end]
            col_base = ".1.3.6.1.4.1.45.1.6.3.3.1.1.10.6"
            if index.startswith(col_base):
                item = index[len(col_base) + 1:]
            else:
                item = index
            discovery.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d fan chassis" % len(discovery), "data": {"discovery": discovery}}
    # Check mode.
    item = params.get("item", "")
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), params.get("host", "localhost"), "-Oqv", ".1.3.6.1.4.1.45.1.6.3.3.1.1.10.6." + item], mutates=False)
    if res.rc != 0 or res.skipped:
        return {"changed": False, "msg": "no such fan chassis item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status = res.stdout.strip()
    return _grade(status, item)


STATE_MAP = {
    "1": ("Other", "UNKNOWN"),
    "2": ("Not available", "UNKNOWN"),
    "3": ("Removed", "OK"),
    "4": ("Disabled", "OK"),
    "5": ("Normal", "OK"),
    "6": ("Reset in Progress", "WARN"),
    "7": ("Testing", "WARN"),
    "8": ("Warning", "WARN"),
    "9": ("Non fatal error", "WARN"),
    "10": ("Fatal error", "CRIT"),
    "11": ("Not configured", "WARN"),
    "12": ("Obsoleted", "OK"),
}


def _grade(status, item):
    entry = STATE_MAP.get(status)
    if entry == None:
        return {"changed": False, "msg": "Fan Chassis %s: Unknown fan status: %s" % (item, status), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    text, state = entry
    return {"changed": False, "msg": "Fan Chassis %s %s" % (item, text), "data": {"state": state, "metrics": {}, "details": ""}}