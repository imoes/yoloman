# canon_pages.star — translated Checkmk check "canon_pages" (printer page counts)
# READ-ONLY SNMP-based check. Discovers page-count OIDs from Canon printers via SNMP.

PAGE_CODES = {
    "301": "total",
    "112": "bw_a3",
    "113": "bw_a4",
    "122": "color_a3",
    "123": "color_a4",
    "106": "color",
    "109": "bw",
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

CANON_PAGES_BASE_OID = ".1.3.6.1.4.1.1602.1.11.1.3.1"
OID_sysDescr = ".1.3.6.1.2.1.1.1.0"
OID_canonical_total = ".1.3.6.1.4.1.1602.1.1.1.1.0"
OID_canonical_page301 = ".1.3.6.1.4.1.1602.1.11.1.3.1.4.301"


def _strip_type_tag(s):
    idx = s.find(": ")
    if idx >= 0:
        s = s[idx + 2:]
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    return s


def _total(values):
    total = 0
    for v in values:
        total = total + v
    return total


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        res_desc = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_sysDescr], mutates=False)
        if res_desc.rc != 0:
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": []}}
        sysdescr = _strip_type_tag(res_desc.stdout)
        if "canon" not in sysdescr.lower():
            return {"changed": False, "msg": "not a Canon printer", "data": {"discovery": []}}

        res_total = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_canonical_total], mutates=False)
        if res_total.rc != 0:
            return {"changed": False, "msg": "Canon total OID not found", "data": {"discovery": []}}

        res_301 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_canonical_page301], mutates=False)
        if res_301.rc != 0:
            return {"changed": False, "msg": "Canon pages OID not found", "data": {"discovery": []}}

        metrics = ["pages_total"]
        for name in PAGE_CODES.values():
            if name != "total":
                metrics.append("pages_" + name)

        return {
            "changed": False,
            "msg": "discovered 1 printer pages service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": metrics}
                ],
            },
        }

    item = params.get("item", "")

    res_desc = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_sysDescr], mutates=False)
    if res_desc.rc != 0:
        return {"changed": False, "msg": "no SNMP response", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysdescr = _strip_type_tag(res_desc.stdout)
    if "canon" not in sysdescr.lower():
        return {"changed": False, "msg": "not a Canon printer", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res_total = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_canonical_total], mutates=False)
    if res_total.rc != 0:
        return {"changed": False, "msg": "Canon total OID not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res_301 = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_canonical_page301], mutates=False)
    if res_301.rc != 0:
        return {"changed": False, "msg": "Canon pages OID not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    walk_oid = CANON_PAGES_BASE_OID + ".4"
    res_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, walk_oid], mutates=False)
    if res_walk.rc != 0:
        return {"changed": False, "msg": "failed to walk Canon page table", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = {}
    for line in res_walk.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value_str = line[sp + 1:].strip()
        idx = oid.rfind(".")
        if idx < 0:
            continue
        page_code = oid[idx + 1:]
        if not value_str:
            continue
        if not value_str.isdigit():
            continue
        if page_code in PAGE_CODES:
            key = "pages_" + PAGE_CODES[page_code]
            section[key] = int(value_str)

    if not section:
        return {"changed": False, "msg": "no page data found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    parts = []
    overall = "OK"

    if "pages_total" not in section:
        total_val = _total(section.values())
        metrics["pages_total"] = float(total_val)
        parts.append("total prints: " + str(total_val))
        warn_total = params.get("pages_total_warn", 0)
        crit_total = params.get("pages_total_crit", 0)
        st = "OK"
        if crit_total > 0 and total_val >= crit_total:
            st = "CRIT"
        elif warn_total > 0 and total_val >= warn_total:
            st = "WARN"
        if st == "CRIT":
            overall = "CRIT"
        elif st == "WARN":
            overall = "WARN"
    else:
        total_val = section["pages_total"]
        metrics["pages_total"] = float(total_val)
        parts.append("total prints: " + str(total_val))
        warn_total = params.get("pages_total_warn", 0)
        crit_total = params.get("pages_total_crit", 0)
        st = "OK"
        if crit_total > 0 and total_val >= crit_total:
            st = "CRIT"
        elif warn_total > 0 and total_val >= warn_total:
            st = "WARN"
        if st == "CRIT":
            overall = "CRIT"
        elif st == "WARN" and overall != "CRIT":
            overall = "WARN"

    sorted_items = sorted(section.items())
    for pages_type, pages in sorted_items:
        if pages_type in PRINTER_PAGES_TYPES:
            metrics[pages_type] = float(pages)
            label = PRINTER_PAGES_TYPES[pages_type]
            parts.append(label + ": " + str(pages))
            wkey = pages_type + "_warn"
            ckey = pages_type + "_crit"
            warn_v = params.get(wkey, 0)
            crit_v = params.get(ckey, 0)
            st = "OK"
            if crit_v > 0 and pages >= crit_v:
                st = "CRIT"
            elif warn_v > 0 and pages >= warn_v:
                st = "WARN"
            if st == "CRIT":
                overall = "CRIT"
            elif st == "WARN" and overall != "CRIT":
                overall = "WARN"

    summary = ", ".join(parts)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": overall,
            "metrics": metrics,
            "details": "",
        },
    }