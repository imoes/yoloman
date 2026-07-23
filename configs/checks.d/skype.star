def main(ctx, params):
    if params.get("_discover"):
        tables_required = [
            "LS:WEB - Address Book Web Query",
            "LS:WEB - Location Information Service",
            "LS:WEB - Distribution List Expansion",
            "LS:WEB - UCWA",
            "ASP.NET Apps v4.0.30319",
        ]
        res = ctx.run(["wmic", "class", "root\\cimv2", "get", "/format:csv"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        items_found = []
        for line in lines[1:]:
            if not line.strip():
                continue
            fields = line.split(",")
            if len(fields) < 1:
                continue
            class_name = fields[0].strip()
            for req in tables_required:
                if class_name == req:
                    items_found.append({
                        "item": "",
                        "params": {
                            "failed_search_requests": {"upper": (1.0, 2.0)},
                            "failed_locations_requests": {"upper": (1.0, 2.0)},
                            "timedout_ad_requests": {"upper": (0.01, 0.02)},
                            "5xx_responses": {"upper": (1.0, 2.0)},
                            "asp_requests_rejected": {"upper": (1, 2)},
                            "failed_file_requests": {"upper": (1.0, 2.0)},
                            "join_failures": {"upper": (1, 2)},
                            "failed_validate_cert": {"upper": (1, 2)},
                        },
                        "metrics": [
                            "failed_search_requests",
                            "failed_location_requests",
                            "failed_ad_requests",
                            "http_5xx",
                            "asp_requests_rejected",
                            "failed_file_requests",
                            "join_failures",
                            "failed_validate_cert_calls",
                        ]
                    })
                    break
        unique_items = []
        seen_items = set()
        for item in items_found:
            key = item["item"]
            if key not in seen_items:
                seen_items.add(key)
                unique_items.append(item)
        return {"changed": False, "msg": "discovered %d items" % len(unique_items),
                "data": {"discovery": unique_items}}

    item = params.get("item", "")
    tables_to_query = [
        "LS:WEB - Address Book Web Query",
        "LS:WEB - Location Information Service",
        "LS:WEB - Distribution List Expansion",
        "LS:WEB - UCWA",
        "ASP.NET Apps v4.0.30319",
        "LS:WEB - Address Book File Download",
        "LS:JoinLauncher - Join Launcher Service Failures",
        "LS:WEB - Auth Provider related calls",
    ]
    wmi_data = {}
    for tbl in tables_to_query:
        res = ctx.run(["wmic", "class", tbl, "get", "/format:csv"], mutates=False)
        if res.rc != 0 or not res.stdout:
            continue
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            continue
        header = [h.strip() for h in lines[0].split(",")]
        rows = []
        for line in lines[1:]:
            if not line.strip():
                continue
            fields = [f.strip() for f in line.split(",")]
            if len(fields) >= len(header):
                rows.append(dict(zip(header, fields)))
        if rows:
            wmi_data[tbl] = rows

    def get_value(table_rows, column):
        if not table_rows:
            return None
        first_row = table_rows[0]
        val = first_row.get(column)
        if val == None or val == "":
            return None
        # Guard: check if string represents a number before conversion
        cleaned = val.strip()
        is_int_like = (cleaned.replace(".", "", 1).replace("-", "", 1).isdigit() if cleaned else False)
        if "." in cleaned:
            if not cleaned.replace("-", "", 1).replace(".", "", 1).isdigit():
                return None
            return float(cleaned)
        else:
            if not cleaned.replace("-", "", 1).isdigit():
                return None
            return float(cleaned)

    metrics = {}
    details_parts = []

    val = get_value(wmi_data.get("LS:WEB - Address Book Web Query"), "WEB - Failed search requests/sec")
    if val != None:
        metrics["failed_search_requests"] = val
        warn = params.get("failed_search_requests", {}).get("upper", (1.0, 2.0))[0]
        crit = params.get("failed_search_requests", {}).get("upper", (1.0, 2.0))[1]
        if crit != None and val >= crit:
            details_parts.append("Failed search requests/sec: %f (>= %f CRIT)" % (val, crit))
        elif warn != None and val >= warn:
            details_parts.append("Failed search requests/sec: %f (>= %f WARN)" % (val, warn))
        else:
            details_parts.append("Failed search requests/sec: %f OK" % val)

    val = get_value(wmi_data.get("LS:WEB - Location Information Service"), "WEB - Failed Get Locations Requests/Second")
    if val != None:
        metrics["failed_location_requests"] = val
        warn = params.get("failed_locations_requests", {}).get("upper", (1.0, 2.0))[0]
        crit = params.get("failed_locations_requests", {}).get("upper", (1.0, 2.0))[1]
        if crit != None and val >= crit:
            details_parts.append("Failed location requests/sec: %f (>= %f CRIT)" % (val, crit))
        elif warn != None and val >= warn:
            details_parts.append("Failed location requests/sec: %f (>= %f WARN)" % (val, warn))
        else:
            details_parts.append("Failed location requests/sec: %f OK" % val)

    val = get_value(wmi_data.get("LS:WEB - Distribution List Expansion"), "WEB - Timed out Active Directory Requests/sec")
    if val != None:
        metrics["failed_ad_requests"] = val
        warn = params.get("timedout_ad_requests", {}).get("upper", (0.01, 0.02))[0]
        crit = params.get("timedout_ad_requests", {}).get("upper", (0.01, 0.02))[1]
        if crit != None and val >= crit:
            details_parts.append("Timeout AD requests/sec: %f (>= %f CRIT)" % (val, crit))
        elif warn != None and val >= warn:
            details_parts.append("Timeout AD requests/sec: %f (>= %f WARN)" % (val, warn))
        else:
            details_parts.append("Timeout AD requests/sec: %f OK" % val)

    val = get_value(wmi_data.get("LS:WEB - UCWA"), "UCWA - HTTP 5xx Responses/Second")
    if val != None:
        metrics["http_5xx"] = val
        warn = params.get("5xx_responses", {}).get("upper", (1.0, 2.0))[0]
        crit = params.get("5xx_responses", {}).get("upper", (1.0, 2.0))[1]
        if crit != None and val >= crit:
            details_parts.append("HTTP 5xx/sec: %f (>= %f CRIT)" % (val, crit))
        elif warn != None and val >= warn:
            details_parts.append("HTTP 5xx/sec: %f (>= %f WARN)" % (val, warn))
        else:
            details_parts.append("HTTP 5xx/sec: %f OK" % val)

    val = get_value(wmi_data.get("ASP.NET Apps v4.0.30319"), "Requests Rejected")
    if val != None:
        metrics["asp_requests_rejected"] = val
        warn = params.get("asp_requests_rejected", {}).get("upper", (1, 2))[0]
        crit = params.get("asp_requests_rejected", {}).get("upper", (1, 2))[1]
        if crit != None and val >= crit:
            details_parts.append("Requests rejected: %d (>= %d CRIT)" % (val, crit))
        elif warn != None and val >= warn:
            details_parts.append("Requests rejected: %d (>= %d WARN)" % (val, warn))
        else:
            details_parts.append("Requests rejected: %d OK" % val)

    if "LS:WEB - Address Book File Download" in wmi_data:
        val = get_value(wmi_data.get("LS:WEB - Address Book File Download"), "WEB - Failed File Requests/Second")
        if val != None:
            metrics["failed_file_requests"] = val
            warn = params.get("failed_file_requests", {}).get("upper", (1.0, 2.0))[0]
            crit = params.get("failed_file_requests", {}).get("upper", (1.0, 2.0))[1]
            if crit != None and val >= crit:
                details_parts.append("Failed file requests/sec: %f (>= %f CRIT)" % (val, crit))
            elif warn != None and val >= warn:
                details_parts.append("Failed file requests/sec: %f (>= %f WARN)" % (val, warn))
            else:
                details_parts.append("Failed file requests/sec: %f OK" % val)

    if "LS:JoinLauncher - Join Launcher Service Failures" in wmi_data:
        val = get_value(wmi_data.get("LS:JoinLauncher - Join Launcher Service Failures"), "JOINLAUNCHER - Join failures")
        if val != None:
            metrics["join_failures"] = val
            warn = params.get("join_failures", {}).get("upper", (1, 2))[0]
            crit = params.get("join_failures", {}).get("upper", (1, 2))[1]
            if crit != None and val >= crit:
                details_parts.append("Join failures: %d (>= %d CRIT)" % (val, crit))
            elif warn != None and val >= warn:
                details_parts.append("Join failures: %d (>= %d WARN)" % (val, warn))
            else:
                details_parts.append("Join failures: %d OK" % val)

    if "LS:WEB - Auth Provider related calls" in wmi_data:
        val = get_value(wmi_data.get("LS:WEB - Auth Provider related calls"), "WEB - Failed validate cert calls to the cert auth provider")
        if val != None:
            metrics["failed_validate_cert_calls"] = val
            warn = params.get("failed_validate_cert", {}).get("upper", (1, 2))[0]
            crit = params.get("failed_validate_cert", {}).get("upper", (1, 2))[1]
            if crit != None and val >= crit:
                details_parts.append("Failed cert validations: %d (>= %d CRIT)" % (val, crit))
            elif warn != None and val >= warn:
                details_parts.append("Failed cert validations: %d (>= %d WARN)" % (val, warn))
            else:
                details_parts.append("Failed cert validations: %d OK" % val)

    state = "OK"
    for name, crit in [
        ("failed_search_requests", params.get("failed_search_requests", {}).get("upper", (1.0, 2.0))[1]),
        ("failed_location_requests", params.get("failed_locations_requests", {}).get("upper", (1.0, 2.0))[1]),
        ("failed_ad_requests", params.get("timedout_ad_requests", {}).get("upper", (0.01, 0.02))[1]),
        ("http_5xx", params.get("5xx_responses", {}).get("upper", (1.0, 2.0))[1]),
        ("asp_requests_rejected", params.get("asp_requests_rejected", {}).get("upper", (1, 2))[1]),
    ]:
        if name in metrics and crit != None and metrics[name] >= crit:
            state = "CRIT"
            break

    if state == "OK":
        for name, crit in [
            ("failed_file_requests", params.get("failed_file_requests", {}).get("upper", (1.0, 2.0))[1]),
            ("join_failures", params.get("join_failures", {}).get("upper", (1, 2))[1]),
            ("failed_validate_cert_calls", params.get("failed_validate_cert", {}).get("upper", (1, 2))[1]),
        ]:
            if name in metrics and crit != None and metrics[name] >= crit:
                state = "CRIT"
                break

    if state == "OK":
        for name, warn in [
            ("failed_search_requests", params.get("failed_search_requests", {}).get("upper", (1.0, 2.0))[0]),
            ("failed_location_requests", params.get("failed_locations_requests", {}).get("upper", (1.0, 2.0))[0]),
            ("failed_ad_requests", params.get("timedout_ad_requests", {}).get("upper", (0.01, 0.02))[0]),
            ("http_5xx", params.get("5xx_responses", {}).get("upper", (1.0, 2.0))[0]),
            ("asp_requests_rejected", params.get("asp_requests_rejected", {}).get("upper", (1, 2))[0]),
            ("failed_file_requests", params.get("failed_file_requests", {}).get("upper", (1.0, 2.0))[0]),
            ("join_failures", params.get("join_failures", {}).get("upper", (1, 2))[0]),
            ("failed_validate_cert_calls", params.get("failed_validate_cert", {}).get("upper", (1, 2))[0]),
        ]:
            if name in metrics and warn != None and metrics[name] >= warn:
                state = "WARN"
                break

    if state == "OK" and not metrics:
        return {"changed": False, "msg": "no relevant WMI data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    summary = "Skype Web Components OK"
    if state != "OK":
        summary = "Skype Web Components %s" % state
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": "; ".join(details_parts)}}