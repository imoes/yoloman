def main(ctx, params):
    # SNMP parameters with Checkmk defaults
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery mode: enumerate services
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.23867.3.1.1.1.4"
        ], mutates=False)
        has_alarms = res.rc == 0 and res.stdout.find("spsActiveAlarmCount") != -1
        discovery = []
        if has_alarms:
            discovery.append({"item": "", "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d service(s)" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode: process alarms for the single service (item is always "")
    # First: get alarm count
    res_cnt = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.23867.3.1.1.1.4"
    ], mutates=False)
    if res_cnt.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error querying alarm count",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse alarm count
    alarm_count = 0
    lines = res_cnt.stdout.splitlines()
    for line in lines:
        if line.find("spsActiveAlarmCount") != -1:
            parts = line.rsplit(" ", 1)
            if len(parts) == 2:
                val = parts[1]
                if val.isdigit():
                    alarm_count = int(val)
                    break

    # Get all alarms: OID base for alarms: .1.3.6.1.4.1.23867.3.1.1.2.1.1
    res_alarms = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.23867.3.1.1.2.1.1"
    ], mutates=False)

    # Parse alarm data into structured list
    alarms = []
    if res_alarms.rc == 0:
        severity_map = {
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

        # Collect alarm entries by index: index -> {severity, descr, source}
        entries = {}
        for line in res_alarms.stdout.splitlines():
            # Format: OID = type: value
            if line.find(" = ") == -1:
                continue
            oid_part, value_part = line.rsplit(" = ", 1)
            value = value_part.strip()
            # Strip type prefix if present (e.g., "STRING: ")
            if value.find(": ") != -1:
                value = value.split(": ", 1)[1].strip().strip('"')

            # Determine OID suffix (last number in OID)
            # oid_part like: .1.3.6.1.4.1.23867.3.1.1.2.1.1.3.1
            suffix_parts = oid_part.rsplit(".", 1)
            if len(suffix_parts) != 2:
                continue
            index_str = suffix_parts[1]
            index = int(index_str) if index_str.isdigit() else -1
            suffix_oid = suffix_parts[0].rsplit(".", 1)[1] if suffix_parts[0].find(".") != -1 else ""

            # Map suffix to field
            # 3 -> severity, 5 -> descr, 6 -> source
            if suffix_oid == "3":
                entries.setdefault(index, {})["severity"] = value
            elif suffix_oid == "5":
                entries.setdefault(index, {})["descr"] = value
            elif suffix_oid == "6":
                entries.setdefault(index, {})["source"] = value

        # Build alarms list
        for index, data in entries.items():
            sev = data.get("severity", "-1")
            state_text, state = severity_map.get(sev, ("unknown", "UNKNOWN"))
            alarm_entry = {
                "state": state,
                "descr": data.get("descr", ""),
                "source": data.get("source", ""),
                "severity_as_text": state_text
            }
            alarms.append(alarm_entry)

    # Compute verdict
    cnt_ok = len([a for a in alarms if a["state"] == "OK"])
    cnt_warn = len([a for a in alarms if a["state"] == "WARN"])
    cnt_crit = len([a for a in alarms if a["state"] == "CRIT"])
    cnt_unkn = len([a for a in alarms if a["state"] == "UNKNOWN"])

    if alarm_count == 0:
        return {
            "changed": False,
            "msg": "No active alarms.",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    summary = "%d active alarms. OK: %d, WARN: %d, CRIT: %d, UNKNOWN: %d" % (
        alarm_count, cnt_ok, cnt_warn, cnt_crit, cnt_unkn)

    details_lines = []
    for elem in alarms:
        details_lines.append("Alarm: {}, Alarm-Source: {}, Severity: {}".format(
            elem["descr"], elem["source"], elem["severity_as_text"]))

    # Determine overall state: prioritize CRIT > WARN > UNKNOWN > OK
    overall_state = "OK"
    if cnt_crit > 0:
        overall_state = "CRIT"
    elif cnt_warn > 0:
        overall_state = "WARN"
    elif cnt_unkn > 0:
        overall_state = "UNKNOWN"

    details = "\n".join(details_lines)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": overall_state, "metrics": {}, "details": details}
    }