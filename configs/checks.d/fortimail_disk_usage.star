def main(ctx, params):
    # This is a Fortinet FortiMail SNMP check.
    # The data source is the FortiMail device itself, queried over SNMP.
    # The OID base is .1.3.6.1.4.1.12356.105.1, metric OID is .9 (fmlSysMailDiskUsage).
    # Detection: .1.3.6.1.2.1.1.2.0 equals .1.3.6.1.4.1.12356.105 (FortiMail sysObjectID).
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        # Probe the real thing: the FortiMail sysObjectID (DETECT_FORTIMAIL).
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv",
             host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout:
            # Device not present / not a FortiMail -> no service.
            return {"changed": False, "msg": "device not present",
                    "data": {"discovery": []}}

        sys_oid = res.stdout.strip()
        if sys_oid != ".1.3.6.1.4.1.12356.105":
            # Not a FortiMail appliance -> absent.
            return {"changed": False, "msg": "not a FortiMail device",
                    "data": {"discovery": []}}

        # FortiMail present -> single-service check, one item ("").
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"disk_usage": (80.0, 90.0)},
                     "metrics": ["disk_utilization"]},
                ]}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    warn, crit = params.get("disk_usage", (80.0, 90.0))

    # Fetch the metric OID directly (-Oqv = bare value).
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv",
         host, ".1.3.6.1.4.1.12356.105.1.9"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return {"changed": False,
                "msg": "no disk usage data (snmpget rc=%d)" % res.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    usage = float(raw) if raw else 0.0

    if usage >= crit:
        state = "CRIT"
    elif usage >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Disk usage: %f%%" % usage,
            "data": {"state": state,
                     "metrics": {"disk_utilization": usage},
                     "details": ""}}