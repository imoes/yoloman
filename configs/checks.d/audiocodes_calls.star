# Module-level constants for SNMP OIDs
_AUDIOCODES_CALLS_BASE_OID = ".1.3.6.1.4.1.5003.15.3.1.1.1"
_AUDIOCODES_CALLS_OIDS = [
    "1",   # Average Call Duration
    "2",   # Active Calls In
    "3",   # Active Calls Out
    "10",  # Established Calls Rate In
    "11",  # Established Calls Rate Out
    "12",  # Answer Seizure Ratio
    "13",  # Network Effectiveness Ratio
    "35",  # Abnormal Terminated Calls In Total
    "36",  # Abnormal Terminated Calls Out Total
]

def _parse_snmp_output(lines):
    """Parse snmpwalk output lines into a list of (oid, value) pairs."""
    parsed = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        # Format: "OID = TYPE: value" or "OID::TYPE: value"
        idx = line.find(" = ")
        if idx == -1:
            continue
        oid_part = line[:idx].strip()
        value_part = line[idx + 3:].strip()
        # Extract numeric OID (strip leading .1.3.6.1.4.1.5003.15.3.1.1.1.)
        if oid_part.startswith(_AUDIOCODES_CALLS_BASE_OID):
            suffix = oid_part[len(_AUDIOCODES_CALLS_BASE_OID):]
            if suffix.startswith("."):
                suffix = suffix[1:]
            if suffix.isdigit():
                parsed.append((int(suffix), value_part))
        else:
            # Try to parse as plain OID
            idx2 = oid_part.rfind(".")
            if idx2 != -1:
                suffix = oid_part[idx2 + 1:]
                if suffix.isdigit():
                    parsed.append((int(suffix), value_part))
    return parsed

def _get_value_by_oid(oid_list, target_oid):
    for oid, value in oid_list:
        if oid == target_oid:
            # Extract numeric value from "TYPE: value"
            if ": " in value:
                val = value.split(": ", 1)[1]
            else:
                val = value
            return val.strip() if val.strip() else None
    return None

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            _AUDIOCODES_CALLS_BASE_OID
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP query failed",
                    "data": {"discovery": []}}
        
        parsed = _parse_snmp_output(res.stdout.splitlines())
        # We expect exactly one service for this check
        if parsed:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {
                        "answer_seizure_ratio_lower_levels": ("fixed", (60.0, 50.0)),
                        "network_effectiveness_ratio_lower_levels": ("fixed", (95.0, 90.0))
                    }, "metrics": [
                        "audiocodes_average_call_duration",
                        "audiocodes_active_calls_in",
                        "audiocodes_active_calls_out",
                        "audiocodes_established_calls_in",
                        "audiocodes_established_calls_out",
                        "audiocodes_answer_seizure_ratio",
                        "audiocodes_network_effectiveness_ratio",
                        "audiocodes_abnormal_terminated_calls_in_total",
                        "audiocodes_abnormal_terminated_calls_out_total"
                    ]}
                ]}
            }
        else:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

    # Check mode
    # Fetch SNMP data
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        _AUDIOCODES_CALLS_BASE_OID
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = _parse_snmp_output(res.stdout.splitlines())
    
    # Extract values
    avg_duration_val = _get_value_by_oid(parsed, 1)
    active_calls_in_val = _get_value_by_oid(parsed, 2)
    active_calls_out_val = _get_value_by_oid(parsed, 3)
    est_rate_in_val = _get_value_by_oid(parsed, 10)
    est_rate_out_val = _get_value_by_oid(parsed, 11)
    asn_seizure_val = _get_value_by_oid(parsed, 12)
    net_eff_val = _get_value_by_oid(parsed, 13)
    abort_in_val = _get_value_by_oid(parsed, 35)
    abort_out_val = _get_value_by_oid(parsed, 36)

    # Convert to integers where applicable
    avg_duration = int(avg_duration_val) if avg_duration_val and avg_duration_val.isdigit() else None
    active_calls_in = int(active_calls_in_val) if active_calls_in_val and active_calls_in_val.isdigit() else None
    active_calls_out = int(active_calls_out_val) if active_calls_out_val and active_calls_out_val.isdigit() else None
    est_rate_in = int(est_rate_in_val) if est_rate_in_val and est_rate_in_val.isdigit() else None
    est_rate_out = int(est_rate_out_val) if est_rate_out_val and est_rate_out_val.isdigit() else None
    asn_seizure = int(asn_seizure_val) if asn_seizure_val and asn_seizure_val.isdigit() else None
    net_eff = int(net_eff_val) if net_eff_val and net_eff_val.isdigit() else None
    abort_in = int(abort_in_val) if abort_in_val and abort_in_val.isdigit() else None
    abort_out = int(abort_out_val) if abort_out_val and abort_out_val.isdigit() else None

    # Process thresholds (only for levels_lower supported in this check)
    # Default thresholds from plugin
    asn_lower_warn, asn_lower_crit = 60.0, 50.0
    net_lower_warn, net_lower_crit = 95.0, 90.0
    
    asn_levels_lower = params.get("answer_seizure_ratio_lower_levels")
    if asn_levels_lower:
        if isinstance(asn_levels_lower, tuple) and len(asn_levels_lower) == 2:
            asn_lower_warn, asn_lower_crit = float(asn_levels_lower[0]), float(asn_levels_lower[1])
    
    net_levels_lower = params.get("network_effectiveness_ratio_lower_levels")
    if net_levels_lower:
        if isinstance(net_levels_lower, tuple) and len(net_levels_lower) == 2:
            net_lower_warn, net_lower_crit = float(net_levels_lower[0]), float(net_levels_lower[1])

    # Determine state and build message
    state = "OK"
    details_parts = []
    metrics = {}

    # Average call duration
    if avg_duration != None:
        details_parts.append("Average call duration: %s" % avg_duration)
        metrics["audiocodes_average_call_duration"] = avg_duration

    # Active calls
    if active_calls_in != None:
        details_parts.append("Active calls in: %d" % active_calls_in)
        metrics["audiocodes_active_calls_in"] = active_calls_in
    
    if active_calls_out != None:
        details_parts.append("Active calls out: %d" % active_calls_out)
        metrics["audiocodes_active_calls_out"] = active_calls_out

    # Established calls rates
    if est_rate_in != None:
        details_parts.append("Established calls in rate: %f/s" % est_rate_in)
        metrics["audiocodes_established_calls_in"] = est_rate_in
    
    if est_rate_out != None:
        details_parts.append("Established calls out rate: %f/s" % est_rate_out)
        metrics["audiocodes_established_calls_out"] = est_rate_out

    # Answer seizure ratio (lower levels)
    if asn_seizure != None:
        if asn_seizure <= asn_lower_crit:
            state = "CRIT"
        elif asn_seizure <= asn_lower_warn:
            state = "WARN" if state == "OK" else state
        details_parts.append("Answer seizure ratio: %d%%" % asn_seizure)
        metrics["audiocodes_answer_seizure_ratio"] = asn_seizure

    # Network effectiveness ratio (lower levels)
    if net_eff != None:
        if net_eff <= net_lower_crit:
            state = "CRIT"
        elif net_eff <= net_lower_warn:
            state = "WARN" if state == "OK" else state
        details_parts.append("Network effectiveness ratio: %d%%" % net_eff)
        metrics["audiocodes_network_effectiveness_ratio"] = net_eff

    # Abnormal terminated calls
    if abort_in != None:
        details_parts.append("Abnormal terminated calls in: %d" % abort_in)
        metrics["audiocodes_abnormal_terminated_calls_in_total"] = abort_in
    
    if abort_out != None:
        details_parts.append("Abnormal terminated calls out: %d" % abort_out)
        metrics["audiocodes_abnormal_terminated_calls_out_total"] = abort_out

    # If no data was gathered at all, return UNKNOWN
    if not metrics:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Format message
    msg = ", ".join(details_parts)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
