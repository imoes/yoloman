def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for Ricoh device via sysObjectID detection
    sysid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysid_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovery: no SNMP response", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "no SNMP response from host", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sysid = sysid_res.stdout.strip()
    is_ricoh = sysid.startswith(".1.3.6.1.4.1.367.1.1")
    if not is_ricoh:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovery: not a Ricoh printer", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "host is not a Ricoh printer", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Verify Ricoh-specific OID existence (ricohPages MIB)
    ricoh_oid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.367.3.2.1.2.19.5.1.5.1"], mutates=False)
    if ricoh_oid_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovery: Ricoh pages OID not present", "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "Ricoh pages OID not present on host", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Check mode: discover / check
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "warn_pages_total": None,
                            "crit_pages_total": None,
                            "warn_pages_color": None,
                            "crit_pages_color": None,
                            "warn_pages_bw": None,
                            "crit_pages_bw": None,
                        },
                        "metrics": ["pages_total", "pages_color", "pages_bw"],
                    },
                ],
                "host_labels": {"cmk/printer_manufacturer": "ricoh"},
            },
        }

    # Fetch the two OID columns from the Ricoh pages table
    col5_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.367.3.2.1.2.19.5.1.5"], mutates=False)
    col9_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.367.3.2.1.2.19.5.1.9"], mutates=False)

    if col5_res.rc != 0 or col9_res.rc != 0:
        return {"changed": False, "msg": "failed to fetch Ricoh pages data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    METRIC_NAMES = {
        "Counter: Machine Total": "pages_total",
        "Total Prints: Color": "pages_color",
        "Total Prints: Black & White": "pages_bw",
    }

    rows = {}
    for line in col5_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            oid, value = parts
            index = oid[len(".1.3.6.1.4.1.367.3.2.1.2.19.5.1.5") + 1:]
            if index not in rows:
                rows[index] = {}
            rows[index]["name"] = value.strip()

    for line in col9_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            oid, value = parts
            index = oid[len(".1.3.6.1.4.1.367.3.2.1.2.19.5.1.9") + 1:]
            if index not in rows:
                rows[index] = {}
            rows[index]["pages_text"] = value.strip()

    section = {}
    for index, row in rows.items():
        if "name" in row and "pages_text" in row and row["name"] in METRIC_NAMES:
            name = row["name"]
            pages_text = row["pages_text"]
            digits = pages_text.lstrip("-")
            if digits.isdigit():
                section[METRIC_NAMES[name]] = int(pages_text)

    if not section:
        return {"changed": False, "msg": "no page counter data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Replicate check_printer_pages_types logic
    metrics = {}
    details_lines = []

    if "pages_total" not in section:
        total = 0
        for v in section.values():
            total = total + v
        metrics["pages_total"] = total
        details_lines.append("total prints: " + str(total))
    else:
        metrics["pages_total"] = section.get("pages_total", 0)
        details_lines.append("total prints: " + str(section.get("pages_total", 0)))
        metrics["pages_color"] = section.get("pages_color", 0)
        details_lines.append("color: " + str(section.get("pages_color", 0)))
        metrics["pages_bw"] = section.get("pages_bw", 0)
        details_lines.append("b/w: " + str(section.get("pages_bw", 0)))

    # No threshold levels defined in this check — pure OK
    state = "OK"
    msg = "; ".join(details_lines)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "\n".join(details_lines),
        },
    }