METRIC_NAMES = {
    "Counter: Machine Total": "pages_total",
    "Total Prints: Color": "pages_color",
    "Total Prints: Black & White": "pages_bw",
}

PRINTER_PAGES_TYPES = {
    "pages_total": "total prints",
    "pages_color": "color",
    "pages_bw": "b/w",
    "pages_a4": "A4",
    "pages_a3": "A3",
    "pages_color_a4": "color A4",
    "pages_bw_a4": "b/w A4",
    "pages_color_a3": "color A3",
    "pages_bw_a3": "b/w A3",
}

def main(ctx, params):
    # Discovery mode: always yield one service with item ""
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": list(METRIC_NAMES.values())}]},
        }

    # Check mode: fetch SNMP data using snmpwalk with the correct OID range
    # The agent provides this data in the checkmk agent output, so we simulate
    # fetching the raw SNMP data via a direct walk.
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.367.3.2.1.2.19.5.1"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse the raw snmpwalk output into a section dict
    section = {}
    lines = res.stdout.splitlines()
    # Build a mapping of index to (name, value)
    names = {}
    values = {}
    for line in lines:
        line = line.strip()
        # Name OID: .1.3.6.1.4.1.367.3.2.1.2.19.5.1.5.1 = STRING:"Counter: Machine Total"
        if line.find(".1.3.6.1.4.1.367.3.2.1.2.19.5.1.5.1") != -1:
            idx = line.find('":')
            if idx != -1:
                names["5"] = line[idx + 2:].strip(' "')
        # Value OID: .1.3.6.1.4.1.367.3.2.1.2.19.5.1.9.1 = STRING:"118722"
        elif line.find(".1.3.6.1.4.1.367.3.2.1.2.19.5.1.9.1") != -1:
            idx = line.find('":')
            if idx != -1:
                values["5"] = line[idx + 2:].strip(' "')

    # Map parsed values using METRIC_NAMES
    for key in names:
        if key in values:
            name = names[key]
            pages_text = values[key]
            if name in METRIC_NAMES:
                # Guard: ensure the value is numeric
                if pages_text.isdigit():
                    section[METRIC_NAMES[name]] = int(pages_text)

    # Compute total if missing (sum of all present values)
    if "pages_total" not in section and len(section) > 0:
        total = 0
        for v in section.values():
            total += v
        section["pages_total"] = total

    if not section:
        return {
            "changed": False,
            "msg": "no pages data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Build summary and metrics
    summary_parts = []
    metrics = {}
    for pages_type in sorted(section.keys()):
        pages = section[pages_type]
        if pages_type in PRINTER_PAGES_TYPES:
            summary_parts.append("%s: %d" % (PRINTER_PAGES_TYPES[pages_type], pages))
        metrics[pages_type] = pages

    summary = ", ".join(summary_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": "",
        },
    }
