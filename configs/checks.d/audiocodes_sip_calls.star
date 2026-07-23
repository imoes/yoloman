def main(ctx, params):
    # === Discovery mode ===
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.10.3.1.1.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}

        tel2ip_found = False
        for line in res.stdout.splitlines():
            if line.strip().startswith(".1.3.6.1.4.1.5003.10.3.1.1.1.1.0"):
                tel2ip_found = True
                break

        res2 = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.5003.10.3.1.1.2"
        ], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}

        ip2tel_found = False
        for line in res2.stdout.splitlines():
            if line.strip().startswith(".1.3.6.1.4.1.5003.10.3.1.1.2.1.0"):
                ip2tel_found = True
                break

        if tel2ip_found or ip2tel_found:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": [
                        "tel2ip_attempted_calls", "tel2ip_established_calls",
                        "tel2ip_busy_calls", "tel2ip_no_answer_calls",
                        "tel2ip_no_route_calls", "tel2ip_no_match_calls",
                        "tel2ip_fail_calls", "tel2ip_fax_attempted_calls",
                        "tel2ip_fax_success_calls", "tel2ip_total_duration",
                        "ip2tel_attempted_calls", "ip2tel_established_calls",
                        "ip2tel_busy_calls", "ip2tel_no_answer_calls",
                        "ip2tel_no_route_calls", "ip2tel_no_match_calls",
                        "ip2tel_fail_calls", "ip2tel_fax_attempted_calls",
                        "ip2tel_fax_success_calls", "ip2tel_total_duration"
                    ]}
                ]}
            }
        else:
            return {"changed": False, "msg": "no SIP calls data found",
                    "data": {"discovery": []}}

    # === Check mode (single-service, item is always "") ===
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch tel2ip data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.5003.10.3.1.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    tel2ip = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.startswith(".1.3.6.1.4.1.5003.10.3.1.1.1.1.0 ="):
            val = line.split()[-1]
            if val.isdigit():
                tel2ip = int(val)
                break

    # Fetch ip2tel data
    res2 = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.5003.10.3.1.1.2"
    ], mutates=False)
    if res2.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    ip2tel = None
    for line in res2.stdout.splitlines():
        line = line.strip()
        if line.startswith(".1.3.6.1.4.1.5003.10.3.1.1.2.1.0 ="):
            val = line.split()[-1]
            if val.isdigit():
                ip2tel = int(val)
                break

    # If both are missing, report UNKNOWN
    if tel2ip == None and ip2tel == None:
        return {
            "changed": False,
            "msg": "no SIP calls data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Build metrics and determine state
    metrics = {}
    details_parts = []

    if tel2ip != None:
        metrics["tel2ip_attempted_calls"] = tel2ip
        details_parts.append("Tel2IP attempted: " + str(tel2ip))

    if ip2tel != None:
        metrics["ip2tel_attempted_calls"] = ip2tel
        details_parts.append("IP2Tel attempted: " + str(ip2tel))

    # Since there are no thresholds defined in the source, report OK
    state = "OK"
    msg = ", ".join(details_parts) if details_parts else "SIP calls data present"

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
