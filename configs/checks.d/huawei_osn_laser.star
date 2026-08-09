def _grade_lower(value, levels):
    if levels == None or len(levels) < 2:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if (value <= crit):
        return "CRIT"
    if (value <= warn):
        return "WARN"
    return "OK"


def main(ctx, params):
    if params.get("_discover"):
        sysOid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False)
        if sysOid.rc != 0 or sysOid.stdout.find(".1.3.6.1.4.1.2011.2.25.1") == -1:
            return {"changed": False, "msg": "not a Huawei OSN device",
                    "data": {"discovery": []}}
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.2011.2.25.3.40.50.119.10.1.6.200"],
            mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no laser data",
                    "data": {"discovery": []}}
        out = []
        seen = {}
        base_col_oid = ".1.3.6.1.4.1.2011.2.25.3.40.50.119.10.1.6.200"
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            if not oid.startswith(base_col_oid + "."):
                continue
            idx = oid[len(base_col_oid) + 1:]
            if idx in seen:
                continue
            seen[idx] = True
            out.append({"item": idx,
                         "params": {"levels_low_in": (-160, -180),
                                    "levels_low_out": (-35, -40)},
                         "metrics": ["input_signal_power_dBm",
                                     "output_signal_power_dBm"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.2011.2.25.3.40.50.119.10.1"
    oids = {"6.200": "dbm_out", "2.200": "dbm_in",
            "2.203": "fec_before", "2.252": "fec_correction_before",
            "2.253": "fec_correction_after"}
    values = {}
    for col, label in oids.items():
        r = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), base + "." + col + "." + item],
            mutates=False)
        if r.rc != 0:
            return {"changed": False,
                    "msg": "no such laser: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        values[label] = r.stdout
    if len(values) < 5:
        return {"changed": False, "msg": "incomplete laser data: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dbm_in_str = values.get("dbm_in")
    dbm_out_str = values.get("dbm_out")
    if dbm_in_str == None or dbm_out_str == None:
        return {"changed": False, "msg": "missing laser reading: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dbm_in = float(dbm_in_str) / 10
    dbm_out = float(dbm_out_str) / 10
    levels_in = params.get("levels_low_in", (-160, -180))
    levels_out = params.get("levels_low_out", (-35, -40))
    st_in = _grade_lower(dbm_in, levels_in)
    st_out = _grade_lower(dbm_out, levels_out)
    if st_in == "CRIT" or st_out == "CRIT":
        state = "CRIT"
    elif st_in == "WARN" or st_out == "WARN":
        state = "WARN"
    else:
        state = "OK"
    fec_correction_before = values.get("fec_correction_before", "")
    fec_correction_after = values.get("fec_correction_after", "")
    summary = "In: %f dBm, Out: %f dBm" % (dbm_in, dbm_out)
    details = ""
    if fec_correction_before != "" and fec_correction_after != "":
        summary = summary + ", FEC Correction before/after: %s/%s" % (fec_correction_before, fec_correction_after)
        details = "FEC before/after: %s/%s" % (fec_correction_before, fec_correction_after)
    return {"changed": False, "msg": summary,
            "data": {"state": state,
                     "metrics": {"input_signal_power_dBm": dbm_in,
                                 "output_signal_power_dBm": dbm_out},
                     "details": details}}