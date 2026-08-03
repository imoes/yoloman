def main(ctx, params):
    if params.get("_discover"):
        # Probe: is this a Silverpeak device? Walk the alarm table.
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", "-M", "+/usr/share/snmp/mibs", params.get("host", "localhost"),
             ".1.3.6.1.4.1.23867.3.1.1.2.1.1.5"],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout.strip():
            # Also try the scalar alarm count to distinguish "no device" from "no alarms"
            cnt_res = ctx.run(
                ["snmpget", "-v2c", "-c", params.get("community", "public"),
                 "-Oqv", params.get("host", "localhost"),
                 ".1.3.6.1.4.1.23867.3.1.1.1.4.0"],
                mutates=False,
            )
            if cnt_res.rc != 0 or not cnt_res.stdout.strip():
                return {"changed": False, "msg": "no Silverpeak device found",
                        "data": {"discovery": []}}
            return {"changed": False,
                    "msg": "discovered 1 item",
                    "data": {"discovery": [
                        {"item": "", "params": {}, "metrics": []}
                    ]}}
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Gather alarm count (scalar)
    cnt_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.23867.3.1.1.1.4.0"],
        mutates=False,
    )
    if cnt_res.rc != 0 or not cnt_res.stdout.strip():
        return {"changed": False, "msg": "silverpeak_VX6000: no active alarm count reachable (no Silverpeak device?)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    alarm_cnt = 0
    cnt_str = cnt_res.stdout.strip()
    if cnt_str.isdigit():
        alarm_cnt = int(cnt_str)

    if alarm_cnt == 0:
        return {"changed": False, "msg": "No active alarms.",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    # Walk alarm severity column to enumerate alarms by index
    sev_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         ".1.3.6.1.4.1.23867.3.1.1.2.1.1.3"],
        mutates=False,
    )
    if sev_res.rc != 0 or not sev_res.stdout.strip():
        return {"changed": False, "msg": "silverpeak_VX6000: could not retrieve alarm table (no Silverpeak device?)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    severity_to_states = {
        "0": ("info", "OK"),
        "1": ("warning", "WARN"),
        "2": ("minor", "WARN"),
        "3": ("major", "CRIT"),
        "4": ("critical", "CRIT"),
        "5": ("cleared", "UNKNOWN"),
        "6": ("acknowledged", "UNKNOWN"),
        "7": ("unacknowledged", "UNKNOWN"),
        "8": ("indeterminate", "UNKNOWN"),
    }

    # Build list of index strings from the severity walk
    indices = []
    for line in sev_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        line_oid = parts[0]
        base_oid = ".1.3.6.1.4.1.23867.3.1.1.2.1.1.3"
        if not line_oid.startswith(base_oid + "."):
            continue
        idx = line_oid[len(base_oid) + 1:]
        indices.append(idx)

    alarms = []
    for idx in indices:
        # severity
        sev_val = ""
        sev_r = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.23867.3.1.1.2.1.1.3." + idx],
            mutates=False,
        )
        if sev_r.rc == 0:
            sev_val = sev_r.stdout.strip()
        # descr
        descr_val = ""
        descr_r = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.23867.3.1.1.2.1.1.5." + idx],
            mutates=False,
        )
        if descr_r.rc == 0:
            descr_val = descr_r.stdout.strip().strip('"')
        # source
        source_val = ""
        source_r = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.23867.3.1.1.2.1.1.6." + idx],
            mutates=False,
        )
        if source_r.rc == 0:
            source_val = source_r.stdout.strip().strip('"')
        st_info = severity_to_states.get(sev_val, ("unknown", "UNKNOWN"))
        alarms.append({
            "state": st_info[1],
            "severity_as_text": st_info[0],
            "descr": descr_val,
            "source": source_val,
        })

    cnt_ok = len([a for a in alarms if a["state"] == "OK"])
    cnt_warn = len([a for a in alarms if a["state"] == "WARN"])
    cnt_crit = len([a for a in alarms if a["state"] == "CRIT"])
    cnt_unkn = len([a for a in alarms if a["state"] == "UNKNOWN"])

    summary = "%d active alarms. OK: %d, WARN: %d, CRIT: %d, UNKNOWN: %d" % (
        alarm_cnt, cnt_ok, cnt_warn, cnt_crit, cnt_unkn)

    detail_lines = [summary]
    for elem in alarms:
        detail_lines.append("Alarm: %s, Alarm-Source: %s, Severity: %s" % (
            elem["descr"], elem["source"], elem["severity_as_text"]))
    details = "\n".join(detail_lines)

    overall = "OK"
    if cnt_crit > 0:
        overall = "CRIT"
    elif cnt_warn > 0:
        overall = "WARN"

    return {"changed": False, "msg": summary,
            "data": {"state": overall, "metrics": {}, "details": details}}