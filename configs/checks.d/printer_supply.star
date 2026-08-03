# ===== checkmk.printer_supply translation (SNMP-based, read-only) =====

MAP_UNIT = {
    "3": "ten thousandths of inches",
    "4": "micrometers",
    "7": "impressions",
    "8": "sheets",
    "11": "hours",
    "12": "thousandths of ounces",
    "13": "tenths of grams",
    "14": "hundreths of fluid ounces",
    "15": "tenths of milliliters",
    "16": "feet",
    "17": "meters",
    "18": "items",
    "19": "%",
}

VALID_BLACK_WORDS = ("black", "schwarz", "noir", "negra")
VALID_CYAN_WORDS = ("cyan", "zyan", "cian")
VALID_MAGENTA_WORDS = ("magenta",)
VALID_YELLOW_WORDS = ("yellow", "gelb", "jaune", "amarilla")

PRINTER_MANUFACTURERS = [
    ".1.3.6.1.4.1.2435.2.3.9", ".1.3.6.1.4.1.1602", ".1.3.6.1.4.1.5502",
    ".1.3.6.1.4.1.25278", ".1.3.6.1.4.1.27748", ".1.3.6.1.4.1.11.2.3.9.1",
    ".1.3.6.1.4.1.18334", ".1.3.6.1.4.1.1347", ".1.3.6.1.4.1.2001.1",
    ".1.3.6.1.4.1.1129", ".1.3.6.1.4.1.367", ".1.3.6.1.4.1.236",
    ".1.3.6.1.4.1.253.8.62.1", ".1.3.6.1.4.1.683.6", ".1.3.6.1.4.1.10642",
    ".1.3.6.1.4.1.674", ".1.3.6.1.4.1.345", ".1.3.6.1.4.1.1248",
    ".1.3.6.1.4.1.641.2", ".1.3.6.1.4.1.641.52", ".1.3.6.1.4.1.641.1",
    ".1.3.6.1.4.1.641.3", ".1.3.6.1.4.1.641.51", ".1.3.6.1.4.1.396",
    ".1.3.6.1.4.1.44932", ".1.3.6.1.4.1.1472", ".1.3.6.1.4.1.2385",
    ".1.3.6.1.4.1.186", ".1.3.6.1.4.1.3835", ".1.3.6.1.4.1.2565",
    ".1.3.6.1.4.1.20438", ".1.3.6.1.4.1.33241", ".1.3.6.1.4.1.6345",
    ".1.3.6.1.4.1.2125", ".1.3.6.1.4.1.4228", ".1.3.6.1.4.1.314",
    ".1.3.6.1.4.1.16653", ".1.3.6.1.4.1.28959", ".1.3.6.1.4.1.28708",
    ".1.3.6.1.4.1.79", ".1.3.6.1.4.1.211", ".1.3.6.1.4.1.231",
    ".1.3.6.1.4.1.297", ".1.3.6.1.4.1.3369", ".1.3.6.1.4.1.116",
    ".1.3.6.1.4.1.2", ".1.3.6.1.4.1.28918", ".1.3.6.1.4.1.3793",
    ".1.3.6.1.4.1.11369", ".1.3.6.1.4.1.815", ".1.3.6.1.4.1.102",
    ".1.3.6.1.4.1.1552", ".1.3.6.1.4.1.279", ".1.3.6.1.4.1.10504",
    ".1.3.6.1.4.1.24807", ".1.3.6.1.4.1.42406", ".1.3.6.1.4.1.263",
    ".1.3.6.1.4.1.22624", ".1.3.6.1.4.1.25549", ".1.3.6.1.4.1.128",
    ".1.3.6.1.4.1.294", ".1.3.6.1.4.1.38191", ".1.3.6.1.4.1.950",
    ".1.3.6.1.4.1.25816", ".1.3.6.1.4.1.28878", ".1.3.6.1.4.1.40463",
    ".1.3.6.1.4.1.122", ".1.3.6.1.4.1.119",
]


def _get_supply_unit(raw_unit):
    unit = MAP_UNIT.get(raw_unit, "")
    if unit == "":
        return ""
    if unit == "%":
        return "%"
    return " " + unit


def _any_word_in(words, text):
    for w in words:
        if w and w in text:
            return True
    return False


def _get_supply_color(raw_color, raw_description):
    color = raw_color.lower()
    description = raw_description.lower()
    if color == "black" or _any_word_in(VALID_BLACK_WORDS, description):
        return "black"
    if color == "cyan" or _any_word_in(VALID_CYAN_WORDS, description):
        return "cyan"
    if color == "magenta" or _any_word_in(VALID_MAGENTA_WORDS, description):
        return "magenta"
    if color == "yellow" or _any_word_in(VALID_YELLOW_WORDS, description):
        return "yellow"
    return None


def _get_supply_class(raw_supply_class):
    return "receptacle" if raw_supply_class == "4" else "container"


def _walk_column(ctx, host, community, col_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid], mutates=False)
    if res.rc != 0:
        return {}
    result = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        space_idx = line.find(" ")
        if space_idx < 0:
            continue
        oid = line[:space_idx]
        value = line[space_idx + 1:]
        index = oid[len(col_oid) + 1:]
        result[index] = value
    return result


def _is_printer(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False, ""
    sysobj = res.stdout.strip()
    for oid in PRINTER_MANUFACTURERS:
        if sysobj.startswith(oid):
            exists_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.43.11.1.1.6.1.1"], mutates=False)
            if exists_res.rc != 0:
                return False, ""
            return True, sysobj
    return False, ""


def _parse_supply_section(ctx, host, community):
    color_base = ".1.3.6.1.2.1.43.12.1.1.4"
    color_table = _walk_column(ctx, host, community, color_base)

    desc_table = _walk_column(ctx, host, community, ".1.3.6.1.2.1.43.11.1.1.6")
    unit_table = _walk_column(ctx, host, community, ".1.3.6.1.2.1.43.11.1.1.7")
    max_table = _walk_column(ctx, host, community, ".1.3.6.1.2.1.43.11.1.1.8")
    level_table = _walk_column(ctx, host, community, ".1.3.6.1.2.1.43.11.1.1.9")
    class_table = _walk_column(ctx, host, community, ".1.3.6.1.2.1.43.11.1.1.4")
    colorant_table = _walk_column(ctx, host, community, ".1.3.6.1.2.1.43.11.1.1.3")

    if len(desc_table) == 0:
        return {}

    parsed = {}
    colors = []
    indices = desc_table.keys()

    for index in indices:
        name = desc_table.get(index, "")
        raw_unit = unit_table.get(index, "")
        raw_max = max_table.get(index, "")
        raw_level = level_table.get(index, "")
        raw_class = class_table.get(index, "")
        color_id = colorant_table.get(index, "")

        if not raw_max.lstrip("-").isdigit() or not raw_level.lstrip("-").isdigit():
            continue
        max_capacity = int(raw_max)
        level = int(raw_level)

        if max_capacity == -2 and level == -2:
            continue
        if max_capacity == 0:
            max_capacity = 100

        raw_color = color_table.get(color_id, "")

        if name.startswith("Toner Cartridge") or name.startswith("Image Drum Unit"):
            if raw_color:
                colors.append(raw_color)
            elif colors:
                raw_color = colors[len(colors) - 1]
            if raw_color:
                name = raw_color.title() + " " + name

        name = name.split(" S/N:")[0].strip("\0")
        raw_color = raw_color.rstrip("\0")

        unit = _get_supply_unit(raw_unit)
        color = _get_supply_color(raw_color, name)
        supply_class = _get_supply_class(raw_class)

        desc_stripped = name.strip()
        if desc_stripped == "":
            continue

        parsed[desc_stripped] = {
            "unit": unit,
            "max_capacity": max_capacity,
            "level": level,
            "supply_class": supply_class,
            "color": color,
        }

    return parsed


def _get_fill_level_percentage(supply, upturn_toner):
    max_cap = supply["max_capacity"]
    level = supply["level"]
    if max_cap == 0:
        return 0.0
    pct = 100.0 * level / max_cap
    if supply["supply_class"] == "receptacle":
        pct = 100 - pct
    if upturn_toner:
        pct = 100 - pct
    return pct


def _state_name(val):
    if val == 0:
        return "OK"
    if val == 1:
        return "WARN"
    if val == 2:
        return "CRIT"
    return "UNKNOWN"


def _grade_levels(value, levels_lower):
    warn, crit = levels_lower
    if value <= crit:
        return "CRIT"
    if value <= warn:
        return "WARN"
    return "OK"


def _get_partial_results(supply, params, color_info, metric_name):
    level = supply["level"]
    max_cap = supply["max_capacity"]
    level_unrestricted = level == -1
    capacity_unrestricted = max_cap == -1
    level_unknown = level == -2
    capacity_unknown = max_cap == -2
    some_remaining = level == -3

    results = []

    if level_unrestricted or capacity_unrestricted:
        results.append({"state": "OK", "summary": color_info + "There are no restrictions on this supply"})
    elif some_remaining:
        sclass = supply["supply_class"]
        if sclass == "container":
            state_val = params.get("some_remaining_ink", 1)
            results.append({"state": _state_name(state_val), "summary": color_info + "Some ink remaining"})
        else:
            state_val = params.get("some_remaining_space", 1)
            results.append({"state": _state_name(state_val), "summary": color_info + "Some space remaining"})
    elif level_unknown:
        results.append({"state": "UNKNOWN", "summary": color_info + " Unknown level"})
    elif capacity_unknown:
        results.append({"state": "OK", "summary": "Supply: %d%s" % (level, supply["unit"])})
        results.append({"metric": metric_name, "value": level})

    return results


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        is_printer, _ = _is_printer(ctx, host, community)
        if not is_printer:
            return {"changed": False, "msg": "no printer detected", "data": {"discovery": []}}

        section = _parse_supply_section(ctx, host, community)
        discovery = []
        for key in section.keys():
            color = section[key].get("color")
            metric_name = "supply_toner_" + (color or "other")
            discovery.append({
                "item": key,
                "params": {"levels": (20.0, 10.0), "upturn_toner": False, "some_remaining_ink": 1, "some_remaining_space": 1},
                "metrics": [metric_name],
            })

        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")

    is_printer, _ = _is_printer(ctx, host, community)
    if not is_printer:
        return {"changed": False, "msg": "no printer detected", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _parse_supply_section(ctx, host, community)
    supply = section.get(item)
    if supply == None:
        return {"changed": False, "msg": "no such supply: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    color = supply.get("color")
    color_info = ""
    if color and color not in item.lower():
        color_info = "[" + color + "] "
    metric_name = "supply_toner_" + (color or "other")

    level = supply["level"]
    max_cap = supply["max_capacity"]
    level_unrestricted = level == -1
    capacity_unrestricted = max_cap == -1
    level_unknown = level == -2
    capacity_unknown = max_cap == -2
    some_remaining = level == -3
    has_partial = capacity_unknown or level_unrestricted or level_unknown or some_remaining

    metrics = {}
    details = ""

    if has_partial:
        partial = _get_partial_results(supply, params, color_info, metric_name)
        state = "OK"
        summary = ""
        for r in partial:
            if "metric" in r:
                metrics[r["metric"]] = r["value"]
            if "state" in r:
                state = r["state"]
            if "summary" in r:
                summary = summary + r["summary"]
        return {"changed": False, "msg": summary, "data": {"state": state, "metrics": metrics, "details": details}}

    pct = _get_fill_level_percentage(supply, params.get("upturn_toner", False))
    levels_lower = params.get("levels", (20.0, 10.0))
    state = _grade_levels(pct, levels_lower)
    metrics[metric_name] = pct

    unit = supply["unit"]
    if state == "OK":
        summary = "Supply level remaining: %d%%" % int(pct)
    elif state == "WARN":
        summary = "Supply level remaining: %d%% (warn < %s%%)" % (int(pct), str(levels_lower[0]))
    else:
        summary = "Supply level remaining: %d%% (crit < %s%%)" % (int(pct), str(levels_lower[1]))

    if unit not in ("", "%"):
        extra = "Supply: %d of max. %d%s" % (level, max_cap, unit)
        return {"changed": False, "msg": summary + "; " + extra, "data": {"state": state, "metrics": metrics, "details": details}}

    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": metrics, "details": details}}