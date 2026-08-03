# Translated Checkmk check: audiocodes_system_events (SNMP → read-only Starlark check)
# Monitors active alarms and archived alarm history on AudioCodes devices via SNMP.

def _int_or_zero(s):
    if s == None or s == "":
        return 0
    neg = False
    body = s
    if s.startswith("-"):
        neg = True
        body = s[1:]
    digits = "0123456789"
    for c in body:
        if digits.find(c) == -1:
            return 0
    v = 0
    for c in body:
        v = v * 10 + (ord(c) - 48)
    return -v if neg else v

def _parse_date_and_time(datetime_string):
    if datetime_string == None or datetime_string == "":
        return None
    components = datetime_string.split()
    hex_part = True
    for comp in components:
        if comp == "":
            continue
        is_hex = True
        for c in comp:
            lc = c.lower()
            if not ((lc >= "0" and lc <= "9") or (lc >= "a" and lc <= "f")):
                is_hex = False
                break
        if not is_hex:
            hex_part = False
            break
    if hex_part and len(components) >= 8:
        year = _int_or_zero(components[0]) * 256 + _int_or_zero(components[1])
        month = _int_or_zero(components[2])
        day = _int_or_zero(components[3])
        hour = _int_or_zero(components[4])
        minute = _int_or_zero(components[5])
        second = _int_or_zero(components[6])
        microsecond = _int_or_zero(components[7]) * 100000
        return "%d-%d-%d %d:%d:%d.%d" % (year, month, day, hour, minute, second, microsecond)
    # Fallback: treat as byte string (latin-1). Not expected for SNMP, return raw.
    return datetime_string

_READABLE_SEVERITY = {
    "0": "cleared",
    "1": "indeterminate",
    "2": "warning",
    "3": "minor",
    "4": "major",
    "5": "critical",
}

_DEFAULT_SEVERITY_STATE_MAPPING = {
    "cleared": 0,
    "indeterminate": 3,
    "warning": 1,
    "minor": 1,
    "major": 2,
    "critical": 2,
}

_ALARMS_BASE = ".1.3.6.1.4.1.5003.11.1.1.1.1"
_HISTORY_BASE = ".1.3.6.1.4.1.5003.11.1.2.1.1"

def _strip_snmp_value(raw):
    # Strip leading "<TYPE>: " prefix and surrounding quotes if present.
    # snmpget -Oqv already gives bare value; this is a safety net.
    s = raw
    colon_idx = s.find(":")
    if colon_idx != -1:
        # Check it looks like a type tag (no dots before colon, alpha chars)
        before = s[:colon_idx]
        is_tag = True
        for c in before:
            if not ((c >= "A" and c <= "Z") or (c >= "a" and c <= "z")):
                is_tag = False
                break
        if is_tag and colon_idx + 1 < len(s) and s[colon_idx + 1] == " ":
            s = s[colon_idx + 2:]
    if len(s) >= 2 and s[0] == '"' and s[len(s) - 1] == '"':
        s = s[1:len(s) - 1]
    elif len(s) >= 2 and s[0] == '"' and s[len(s) - 1] == '"':
        s = s[1:len(s) - 1]
    return s

def _snmp_get(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return _strip_snmp_value(res.stdout.strip())

def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        line_oid = line[:sp]
        val = line[sp + 1:]
        # Strip surrounding quotes if present
        if len(val) >= 2 and val[0] == '"' and val[len(val) - 1] == '"':
            val = val[1:len(val) - 1]
        rows.append({"oid": line_oid, "value": val})
    return rows

def _fetch_active_alarms(ctx, host, community):
    # Walk the alarm table columns individually using -Oqv on each column OID.
    # Column OIDs under _ALARMS_BASE:
    #   1: acActiveAlarmSequenceNumber
    #   2: acActiveAlarmSysuptime
    #   4: acActiveAlarmDateAndTime
    #   5: acActiveAlarmName
    #   6: acActiveAlarmTextualDescription
    #   7: acActiveAlarmSource
    #   8: acActiveAlarmSeverity
    cols = {
        "1": "sequence_number",
        "2": "sysuptime",
        "4": "date_and_time",
        "5": "name",
        "6": "description",
        "7": "source",
        "8": "severity",
    }
    # Walk column 1 (sequence number) to discover indices
    indices = _snmp_walk(ctx, host, community, _ALARMS_BASE + ".1")
    alarms = []
    for row in indices:
        index = row["oid"][len(_ALARMS_BASE + ".1") + 1:]
        if index == "":
            continue
        al = {}
        al["sequence_number"] = _strip_snmp_value(row["value"])
        # Fetch other columns by numeric index
        for col, field in cols.items():
            if col == "1":
                al[field] = _strip_snmp_value(row["value"])
                continue
            val = _snmp_get(ctx, host, community, _ALARMS_BASE + "." + col + "." + index)
            al[field] = val if val != None else ""
        alarms.append(al)
    return alarms

def _fetch_archived_history_count(ctx, host, community):
    rows = _snmp_walk(ctx, host, community, _HISTORY_BASE + ".1")
    return len(rows)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe: verify SNMP is reachable on this host/device.
    # Use a basic snmpget on sysDescr (1.3.6.1.2.1.1.1.0) as a liveness check.
    probe = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.1.0"], mutates=False)
    if probe.rc == 127:
        # snmpget binary not installed
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if probe.rc != 0:
        # Device not reachable
        return {"changed": False, "msg": "no SNMP response from " + host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        # Discovery: AudioCodes devices with active alarms / archived history
        # exist if either table returns data.
        alarms = _fetch_active_alarms(ctx, host, community)
        archived_count = _fetch_archived_history_count(ctx, host, community)
        if len(alarms) == 0 and archived_count == 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        mapping = params.get("severity_state_mapping", _DEFAULT_SEVERITY_STATE_MAPPING)
        metrics = []
        # We always expose count metrics
        metrics.append("num_alarms")
        metrics.append("num_critical")
        metrics.append("num_warning")
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"severity_state_mapping": mapping},
                     "metrics": metrics,
                     "service_labels": {"device_model": "audiocodes"}}
                ]}}

    item = params.get("item", "")
    mapping = params.get("severity_state_mapping", _DEFAULT_SEVERITY_STATE_MAPPING)

    alarms = _fetch_active_alarms(ctx, host, community)
    archived_count = _fetch_archived_history_count(ctx, host, community)

    if len(alarms) == 0 and archived_count == 0:
        # Nothing to report — device has no events tables
        return {"changed": False, "msg": "no audiocodes system events data",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    critical_count = 0
    warning_count = 0
    num_alarms = len(alarms)
    details_parts = []

    for alarm in alarms:
        sev_raw = alarm.get("severity", "0")
        sev_readable = _READABLE_SEVERITY.get(sev_raw, "indeterminate")
        state_code = mapping.get(sev_readable, 3)
        if state_code == 1:
            warning_count += 1
        elif state_code == 2:
            critical_count += 1
        seq = alarm.get("sequence_number", "?")
        name = alarm.get("name", "")
        descr = alarm.get("description", "")
        source = alarm.get("source", "")
        sysuptime_raw = alarm.get("sysuptime", "0")
        sysuptime_val = _int_or_zero(sysuptime_raw)
        dt = _parse_date_and_time(alarm.get("date_and_time", ""))
        dt_str = ", Date and Time: " + dt if dt != None else ""
        details_parts.append(
            "Alarm #%s: Name: %s, Severity: %s, Sysuptime: %ss, Description: %s, Source: %s%s"
            % (seq, name, sev_readable, sysuptime_val, descr, source, dt_str)
        )

    overall_state = "CRIT" if critical_count > 0 else ("WARN" if warning_count > 0 else "OK")
    summary = "Critical alarms: %d, Warnings: %d" % (critical_count, warning_count)

    metrics = {
        "num_alarms": num_alarms,
        "num_critical": critical_count,
        "num_warning": warning_count,
    }

    details = "\n".join(details_parts)
    if details == "":
        details = "No active alarms. Archived: %d" % archived_count

    # Emit archived count as part of details/summary
    arch_summary = "Archived: %d" % archived_count
    full_details = details + "\n" + arch_summary

    return {"changed": False, "msg": summary + ", " + arch_summary,
            "data": {"state": overall_state, "metrics": metrics, "details": full_details}}