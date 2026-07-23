def main(ctx, params):
    # Discovery mode: always yields one Service with no item
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": [
                "pages_total",
                "pages_color",
                "pages_bw",
                "pages_a4",
                "pages_a3",
                "pages_color_a4",
                "pages_bw_a4",
                "pages_color_a3",
                "pages_bw_a3",
            ]}]}
        }

    # Check mode: gather SNMP data via snmpwalk
    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
                   ".1.3.6.1.4.1.1602.1.11.1.3.1"], mutates=False)

    # Parse snmpwalk output: "OID = value" lines
    section = {}
    PAGE_CODES = {
        "301": "total",
        "112": "bw_a3",
        "113": "bw_a4",
        "122": "color_a3",
        "123": "color_a4",
        "106": "color",
        "109": "bw",
    }

    for line in res.stdout.splitlines():
        line = line.strip()
        eq_index = line.find(" = ")
        if eq_index == -1:
            continue
        oid = line[:eq_index].strip()
        val = line[eq_index + 3:].strip()
        tokens = oid.split(".")
        if len(tokens) == 0:
            continue
        code = tokens[-1]
        if code in PAGE_CODES:
            # Validate numeric string before conversion
            stripped = val.strip()
            is_negative = False
            if stripped.startswith("-"):
                is_negative = True
                stripped = stripped[1:]
            if stripped.isdigit():
                val_int = int(stripped)
                if is_negative:
                    val_int = -val_int
                section["pages_" + PAGE_CODES[code]] = val_int

    # If pages_total is not present, compute it from sum of all
    if "pages_total" not in section:
        total = 0
        for key in section.keys():
            total = total + section[key]
        section["pages_total"] = total

    # Build result: one result per metric type
    metric_labels = {
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

    summaries = []
    metrics = {}

    # Sort keys for deterministic output
    for pages_type in sorted(section.keys()):
        if pages_type in metric_labels:
            summaries.append(metric_labels[pages_type] + ": " + str(section[pages_type]))
        metrics[pages_type] = section[pages_type]

    msg = ", ".join(summaries) if summaries else "no page data"
    state = "OK"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
