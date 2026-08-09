def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    def _snmpget(oid):
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if res.rc == 127 or res.rc != 0 or not res.stdout:
            return None
        return res.stdout.strip()

    def _snmpget_row(base, oid_list):
        row = []
        for o in oid_list:
            v = _snmpget(base + "." + o)
            row.append(v)
        return row

    if params.get("_discover"):
        sys_oid = _snmpget(".1.3.6.1.2.1.1.2.0")
        if sys_oid == None:
            return {"changed": False, "msg": "no wagner titanus topsense device found",
                    "data": {"discovery": []}}
        if sys_oid != ".1.3.6.1.4.1.34187.21501" and sys_oid != ".1.3.6.1.4.1.34187.74195":
            return {"changed": False, "msg": "no wagner titanus topsense device found",
                    "data": {"discovery": []}}
        sys_table = _snmpget_row(".1.3.6.1.2.1.1", ["1", "3", "4", "5", "6"])
        if sys_table == None:
            return {"changed": False, "msg": "no wagner titanus topsense device found",
                    "data": {"discovery": []}}
        out = [
            {"item": "1", "params": {}, "metrics": ["chamber_deviation"]},
            {"item": "2", "params": {}, "metrics": ["chamber_deviation"]},
        ]
        return {"changed": False, "msg": "discovered %d chamber deviation detectors" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    sys_oid = _snmpget(".1.3.6.1.2.1.1.2.0")
    if sys_oid == None or (sys_oid != ".1.3.6.1.4.1.34187.21501" and sys_oid != ".1.3.6.1.4.1.34187.74195"):
        return {"changed": False, "msg": "no wagner titanus topsense device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_table = _snmpget_row(".1.3.6.1.2.1.1", ["1", "3", "4", "5", "6"])
    if sys_table == None:
        return {"changed": False, "msg": "no wagner titanus topsense device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sys_oid == ".1.3.6.1.4.1.34187.21501":
        ext_table = _snmpget_row(".1.3.6.1.4.1.34187.21501.2.1",
                                 ["245810000", "245820000", "245950000", "246090000",
                                  "245960000", "246100000", "245970000", "246110000", "24584008"])
    else:
        ext_table = _snmpget_row(".1.3.6.1.4.1.34187.74195.2.1",
                                 ["245790000", "245800000", "245940000", "246060000",
                                  "245950000", "246070000", "245960000", "246080000"])
    if ext_table == None or len(ext_table) < 1:
        return {"changed": False, "msg": "no chamber deviation data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item == "1":
        val = ext_table[2]
    elif item == "2":
        val = ext_table[3]
    else:
        return {"changed": False, "msg": "Chamber Deviation Detector %s not found in SNMP" % str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if val == None:
        return {"changed": False, "msg": "no chamber deviation data available for detector %s" % str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    chamber_deviation = float(val)
    return {"changed": False,
            "msg": "%f%% Chamber Deviation" % chamber_deviation,
            "data": {"state": "OK", "metrics": {"chamber_deviation": chamber_deviation}, "details": ""}}