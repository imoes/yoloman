# ===== Starlark check: printer_pages =====

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

OID_PRINTER_PAGES = ".1.3.6.1.2.1.43.10.2.1.4.1.1"

def _sum_values(values):
    total = 0
    for v in values:
        total = total + v
    return total

def main(ctx, params):
    # Discovery mode: always discover a single service
    if params.get("_discover"):
        # Check if the SNMP tree exists by attempting to fetch the OID
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"), OID_PRINTER_PAGES], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            # No printer pages data available
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["pages_total"]}]}}

    # Check mode: fetch current pages data
    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"), OID_PRINTER_PAGES], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        value_str = parts[1].strip()
        # Extract numeric value; handle INTEGER: prefix or raw number
        if ":" in value_str:
            value_str = value_str.split(":", 1)[1].strip()
        if not value_str.isdigit():
            continue
        value = int(value_str)
        # Extract OID leaf: last numeric component after the base OID
        oid_part = parts[0].strip()
        leaf = oid_part.split(".")[-1] if "." in oid_part else oid_part
        # Map leaf to metric names; leaf "1" -> "pages_total"
        if leaf == "1":
            section["pages_total"] = value
        elif leaf == "2":
            section["pages_color"] = value
        elif leaf == "3":
            section["pages_bw"] = value
        elif leaf == "4":
            section["pages_a4"] = value
        elif leaf == "5":
            section["pages_a3"] = value
        elif leaf == "6":
            section["pages_color_a4"] = value
        elif leaf == "7":
            section["pages_bw_a4"] = value
        elif leaf == "8":
            section["pages_color_a3"] = value
        elif leaf == "9":
            section["pages_bw_a3"] = value

    if not section:
        return {"changed": False, "msg": "no pages data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Compute summary and metrics
    summaries = []
    metrics = {}

    # If no pages_total, compute it as sum of all values
    if "pages_total" not in section:
        total = _sum_values(section.values())
        section["pages_total"] = total

    for pages_type, pages in sorted(section.items()):
        if pages_type in PRINTER_PAGES_TYPES:
            summaries.append("%s: %s" % (PRINTER_PAGES_TYPES[pages_type], str(pages)))
            metrics[pages_type] = pages

    summary = ", ".join(summaries)
    return {"changed": False, "msg": summary,
            "data": {"state": "OK", "metrics": metrics, "details": ""}}
