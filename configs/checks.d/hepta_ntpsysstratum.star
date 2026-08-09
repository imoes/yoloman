def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no hepta device detected",
                    "data": {"discovery": []}}
        sysoid = res.stdout.strip()
        if not sysoid.startswith(".1.3.6.1.4.1.12527"):
            return {"changed": False, "msg": "device is not a hepta NTP system",
                    "data": {"discovery": []}}
        out = [
            {"item": "ntpSysStratum", "params": {}, "metrics": []},
            {"item": "SyncModuleTimeSyncState", "params": {}, "metrics": []},
            {"item": "SyncModuleTimeLocal", "params": {}, "metrics": []},
        ]
        return {"changed": False, "msg": "discovered %d hepta services" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    fields = ["device_type", "serial_number", "fw_version", "fw_date", "version",
              "ntp_stratum", "local", "sync_state"]
    oids = ["1.1.0", "1.3.0", "1.4.0", "1.5.0", "1.6.0", "2.1.2.0", "3.1.0", "3.5.0"]
    base1 = ".1.3.6.1.4.1.12527.29"
    base2 = ".1.3.6.1.4.1.12527.40"
    row = {}
    for b in [base1, base2]:
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-Oqv", params.get("host", "localhost"),
                       b + ".1"], mutates=False)
        if res.rc == 0 and res.stdout:
            row["device_type"] = res.stdout
            break
    if not row:
        return {"changed": False, "msg": "no hepta device found via SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = {}
    for i in range(len(oids)):
        val = ""
        for b in [base1, base2]:
            r = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-Oqv", params.get("host", "localhost"), b + "." + oids[i]],
                        mutates=False)
            if r.rc == 0 and r.stdout:
                val = r.stdout
                break
        section[fields[i]] = val
    if item == "ntpSysStratum":
        stratum = section.get("ntp_stratum", "0")
        if stratum == "1":
            return {"changed": False, "msg": "Stratum 1, Primary Reference",
                    "data": {"state": "OK", "metrics": {}, "details": ""}}
        if stratum == "16":
            return {"changed": False, "msg": "Stratum Invalid",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        if stratum == "0":
            return {"changed": False, "msg": "Stratum Unknown",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "Stratum is using secondary reference(via NTP)",
                "data": {"state": "WARN", "metrics": {}, "details": ""}}
    if item == "SyncModuleTimeSyncState":
        st = section.get("sync_state", "")
        if st == "R":
            return {"changed": False, "msg": "Radio synchronous with high precision",
                    "data": {"state": "OK", "metrics": {}, "details": ""}}
        if st == "r":
            return {"changed": False, "msg": "Radio synchronous with low precision",
                    "data": {"state": "WARN", "metrics": {}, "details": ""}}
        if st == "C":
            return {"changed": False, "msg": "Crystal",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        if st == "I":
            return {"changed": False, "msg": "Invalid time and date",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "No data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item == "SyncModuleTimeLocal":
        local = section.get("local", "")
        return {"changed": False, "msg": "Module Time: " + local,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "unknown item: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}