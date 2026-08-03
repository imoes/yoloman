# AudioCodes SIP Calls check - SNMP-based
# Monitors SIP/H.323 call statistics via SNMP from AudioCodes devices

METRIC_KEYS = [
    "attempted_calls",
    "established_calls",
    "busy_calls",
    "no_answer_calls",
    "no_route_calls",
    "no_match_calls",
    "fail_calls",
    "fax_attempted_calls",
    "fax_success_calls",
    "total_duration",
]

METRIC_HEADERS = {
    "attempted_calls": "Number of Attempted SIP/H323 calls",
    "established_calls": "Number of established (connected and voice activated) SIP/H323 calls",
    "busy_calls": "Number of Destination Busy SIP/H323 calls",
    "no_answer_calls": "Number of No Answer SIP/H323 calls",
    "no_route_calls": "Number of No Route SIP/H323 calls. Most likely to be due to wrong number",
    "no_match_calls": "Number of No capability match between peers on SIP/H323 calls",
    "fail_calls": "Number of failed SIP/H323 calls",
    "fax_attempted_calls": "Number of Attempted SIP/H323 fax calls",
    "fax_success_calls": "Number of SIP/H323 fax success calls",
    "total_duration": "Total duration of SIP/H323 calls",
}

TEL2IP_BASE = ".1.3.6.1.4.1.5003.10.3.1.1.1"
IP2TEL_BASE = ".1.3.6.1.4.1.5003.10.3.1.1.2"

def _build_oids(base):
    oids = []
    for i in range(1, 11):
        oids.append(base + "." + str(i) + ".0")
    return oids

def _get_snmp_values(ctx, host, community, oids):
    # Single snmpget with multiple OIDs, -Oqv gives bare values
    argv = ["snmpget", "-v2c", "-c", community, "-Oqv", host] + oids
    res = ctx.run(argv, mutates=False)
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    values = []
    for l in lines:
        v = l.strip()
        values.append(v)
    return values

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn", 0)
    crit = params.get("crit", 0)

    if params.get("_discover"):
        tel2ip_oids = _build_oids(TEL2IP_BASE)
        ip2tel_oids = _build_oids(IP2TEL_BASE)
        tel2ip = _get_snmp_values(ctx, host, community, tel2ip_oids)
        ip2tel = _get_snmp_values(ctx, host, community, ip2tel_oids)
        if tel2ip == None and ip2tel == None:
            return {"changed": False, "msg": "no AudioCodes SIP call data found", "data": {"discovery": []}}
        metric_names = []
        for prefix in ["tel2ip", "ip2tel"]:
            for key in METRIC_KEYS:
                metric_names.append("audiocodes_" + prefix + "_" + key)
        return {"changed": False, "msg": "discovered AudioCodes SIP calls service",
                "data": {"discovery": [{"item": "", "params": {"warn": warn, "crit": crit}, "metrics": metric_names}]}}

    # Check mode
    tel2ip_oids = _build_oids(TEL2IP_BASE)
    ip2tel_oids = _build_oids(IP2TEL_BASE)

    tel2ip_vals = _get_snmp_values(ctx, host, community, tel2ip_oids)
    ip2tel_vals = _get_snmp_values(ctx, host, community, ip2tel_oids)

    if tel2ip_vals == None and ip2tel_vals == None:
        return {"changed": False, "msg": "no AudioCodes SIP call data found (SNMP unavailable)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    state = "OK"
    msgs = []

    # Process tel2ip
    if tel2ip_vals != None and len(tel2ip_vals) >= 10:
        for i, key in enumerate(METRIC_KEYS):
            val = tel2ip_vals[i]
            metric_name = "audiocodes_tel2ip_" + key
            metrics[metric_name] = int(val) if val.lstrip("-").isdigit() else 0
            # Apply levels to attempted_calls and established_calls (non-notice-only)
            if warn > 0 and crit > 0 and key in ("attempted_calls", "established_calls"):
                v = metrics[metric_name]
                if v >= crit:
                    state = "CRIT"
                elif v >= warn:
                    if state != "CRIT":
                        state = "WARN"
        msgs.append("Tel2IP: " + str(len(tel2ip_vals)) + " counters")

    # Process ip2tel
    if ip2tel_vals != None and len(ip2tel_vals) >= 10:
        for i, key in enumerate(METRIC_KEYS):
            val = ip2tel_vals[i]
            metric_name = "audiocodes_ip2tel_" + key
            metrics[metric_name] = int(val) if val.lstrip("-").isdigit() else 0
            if warn > 0 and crit > 0 and key in ("attempted_calls", "established_calls"):
                v = metrics[metric_name]
                if v >= crit:
                    state = "CRIT"
                elif v >= warn:
                    if state != "CRIT":
                        state = "WARN"
        msgs.append("IP2Tel: " + str(len(ip2tel_vals)) + " counters")

    # Build summary with total_duration for both directions
    tel2ip_dur = "N/A"
    ip2tel_dur = "N/A"
    if tel2ip_vals != None and len(tel2ip_vals) >= 10:
        tel2ip_dur = tel2ip_vals[9]
    if ip2tel_vals != None and len(ip2tel_vals) >= 10:
        ip2tel_dur = ip2tel_vals[9]

    summary = "Tel2IP calls, duration: " + tel2ip_dur + "s; IP2Tel calls, duration: " + ip2tel_dur + "s"

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": summary}}