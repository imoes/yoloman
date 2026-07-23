# ===== Starlark check module: printer_supply =====
# Translation of checkmk.printer_supply to read-only Starlark check module

# Map of unit codes to unit strings
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

# Color validation helpers
VALID_BLACK_WORDS = ["black", "schwarz", "noir", "negra"]
VALID_CYAN_WORDS = ["cyan", "zyan", "cian"]
VALID_MAGENTA_WORDS = ["magenta"]
VALID_YELLOW_WORDS = ["yellow", "gelb", "jaune", "amarilla"]


def _get_supply_color(raw_color, raw_description):
    color = raw_color.lower()
    description = raw_description.lower()
    if color == "black":
        return "black"
    for word in VALID_BLACK_WORDS:
        if word in description:
            return "black"
    if color == "cyan":
        return "cyan"
    for word in VALID_CYAN_WORDS:
        if word in description:
            return "cyan"
    if color == "magenta":
        return "magenta"
    for word in VALID_MAGENTA_WORDS:
        if word in description:
            return "magenta"
    if color == "yellow":
        return "yellow"
    for word in VALID_YELLOW_WORDS:
        if word in description:
            return "yellow"
    return None


def _get_supply_unit(raw_unit):
    unit = MAP_UNIT.get(raw_unit, "")
    if unit in ["", "%"]:
        return unit
    return " " + unit


def _get_supply_class(raw_supply_class):
    # 1 = other, 3 = supplyThatIsConsumed (container), 4 = supplyThatIsFilled (receptacle)
    if raw_supply_class == "4":
        return "receptacle"
    return "container"


def _parse_section(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid1 = ".1.3.6.1.2.1.43.12.1.1"
    base_oid2 = ".1.3.6.1.2.1.43.11.1.1"

    # Walk colorant index mapping (base + .4 -> oid_end)
    res1 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid1 + ".4"], mutates=False)
    color_mapping = {}
    for line in res1.stdout.splitlines():
        if line.find("=") == -1:
            continue
        parts = line.strip().split("=", 1)
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        oid_end = oid_part.rsplit(".", 1)[-1]
        color_mapping[oid_end] = val_part

    # Walk supplies data (description, unit, maxcap, level, class, colorant index)
    res2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                    base_oid2 + ".6",  # description
                    base_oid2 + ".7",  # unit
                    base_oid2 + ".8",  # maxCapacity
                    base_oid2 + ".9",  # level
                    base_oid2 + ".4",  # class
                    base_oid2 + ".3",  # colorantIndex
                    ], mutates=False)

    # Parse flat snmpwalk into structured data per index
    parsed = {}
    colors = []
    entries = {}
    for line in res2.stdout.splitlines():
        if line.find("=") == -1:
            continue
        parts = line.strip().split("=", 1)
        oid_part = parts[0].strip()
        val = parts[1].strip()
        # Extract index from OID like .1.3.6.1.2.1.43.11.1.1.6.1.1 -> last two numbers
        # For base .1.3.6.1.2.1.43.11.1.1, the instance index is the last number
        if not oid_part.startswith(base_oid2 + "."):
            continue
        suffix = oid_part[len(base_oid2 + "."):]
        # suffix looks like "6.1.1" or "7.1.1", etc. We need to group by instance index (last number)
        idx = suffix.rsplit(".", 1)[-1]
        # Get the OID base number
        oid_num = suffix.rsplit(".", 1)[0]
        if idx not in entries:
            entries[idx] = {}
        entries[idx][oid_num] = val

    # Process each entry
    for idx in sorted(entries.keys(), key=lambda x: int(x)):
        data = entries[idx]
        description_raw = data.get("6", "").strip("\0")
        raw_unit = data.get("7", "").strip()
        raw_max_capacity = data.get("8", "").strip()
        raw_level = data.get("9", "").strip()
        raw_supply_class = data.get("4", "").strip()
        color_id = data.get("3", "").strip()

        # Skip invalid entries
        if not raw_max_capacity.isdigit() or not raw_level.isdigit():
            continue

        max_capacity = int(raw_max_capacity)
        level = int(raw_level)

        # Skip useless entries (both -2)
        if max_capacity == -2 and level == -2:
            continue

        # Treat 0/0 as 100% capacity
        if max_capacity == 0:
            max_capacity = 100

        # Get raw color from mapping
        raw_color = color_mapping.get(color_id, "").strip("\0")

        # Fix trailing zeros and build description
        description = description_raw.split(" S/N:")[0].strip("\0")

        # Color logic for toners/drum units
        if description.startswith("Toner Cartridge") or description.startswith("Image Drum Unit"):
            if raw_color:
                colors += [raw_color]
            elif raw_color == "" and colors:
                raw_color = colors[len(colors) - 1] if len(colors) > 0 else ""
            if raw_color:
                description = raw_color.title() + " " + description

        unit = _get_supply_unit(raw_unit)
        color = _get_supply_color(raw_color, description)
        supply_class = _get_supply_class(raw_supply_class)

        parsed[description] = {
            "unit": unit,
            "max_capacity": max_capacity,
            "level": level,
            "supply_class": supply_class,
            "color": color,
        }

    return parsed


def _get_fill_level_percentage(supply, upturn_toner):
    fill_level_percentage = 100.0 * supply["level"] / supply["max_capacity"]
    if supply["supply_class"] == "receptacle":
        fill_level_percentage = 100 - fill_level_percentage
    if upturn_toner:
        return 100 - fill_level_percentage
    return fill_level_percentage


def _get_color_info(item, color):
    if color and not color in item.lower():
        return "[" + color + "] "
    return ""


def _get_partial_data_result(supply, params, color_info, metric_name):
    # has_partial_data = (capacity_unknown or level_unrestricted or level_unknown or some_level_remains)
    if supply["level"] == -1 or supply["max_capacity"] == -1:  # unrestricted
        return {
            "state": "OK",
            "summary": color_info + "There are no restrictions on this supply",
        }
    if supply["level"] == -3:  # some_level_remains
        if supply["supply_class"] == "container":
            state = "WARN" if int(params.get("some_remaining_ink", 1)) == 1 else "OK"
            return {"state": state, "summary": color_info + "Some ink remaining"}
        else:
            state = "WARN" if int(params.get("some_remaining_space", 1)) == 1 else "OK"
            return {"state": state, "summary": color_info + "Some space remaining"}
    if supply["level"] == -2 and supply["max_capacity"] == -2:
        # already skipped in parsing, but guard for completeness
        return {"state": "UNKNOWN", "summary": color_info + "Unknown level"}
    if supply["level"] == -2:  # level_unknown
        return {"state": "UNKNOWN", "summary": color_info + "Unknown level"}
    if supply["max_capacity"] == -2:  # capacity_unknown
        return {
            "state": "OK",
            "summary": "Supply: %d%s" % (supply["level"], supply["unit"]),
            "metric": (metric_name, supply["level"]),
        }
    return None


def main(ctx, params):
    if params.get("_discover"):
        section = _parse_section(ctx, params)
        items = []
        for key in section.keys():
            if not key:
                continue
            items.append({
                "item": key,
                "params": {
                    "levels": (20.0, 10.0),
                    "upturn_toner": False,
                    "some_remaining_ink": 1,
                    "some_remaining_space": 1,
                },
                "metrics": ["supply_toner_" + (section[key]["color"] or "other")],
            })
        return {
            "changed": False,
            "msg": "discovered %d supplies" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    section = _parse_section(ctx, params)
    if not item in section:
        return {
            "changed": False,
            "msg": "supply not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    supply = section[item]
    color = supply["color"]
    metric_name = "supply_toner_" + (color if color else "other")

    # Check for partial data first
    has_partial = (supply["max_capacity"] == -2 or supply["level"] == -1 or
                   supply["level"] == -2 or supply["level"] == -3)
    if has_partial:
        res = _get_partial_data_result(supply, params, _get_color_info(item, color), metric_name)
        if res:
            metrics = {}
            if "metric" in res:
                metrics[res["metric"][0]] = res["metric"][1]
            return {
                "changed": False,
                "msg": res["summary"],
                "data": {"state": res["state"], "metrics": metrics, "details": ""},
            }
        # fallback if unexpected
        return {
            "changed": False,
            "msg": "supply data incomplete",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Normal case: compute percentage
    levels = params.get("levels", (20.0, 10.0))
    warn_level = levels[0]
    crit_level = levels[1]
    upturn = params.get("upturn_toner", False)
    pct = _get_fill_level_percentage(supply, upturn)

    # Determine state
    state = "CRIT" if pct <= crit_level else ("WARN" if pct <= warn_level else "OK")

    # Build summary
    color_info = _get_color_info(item, color)
    summary_parts = []
    summary_parts.append(color_info + "Supply level remaining: %d%%" % int(pct))
    if supply["unit"] not in ["", "%"]:
        summary_parts.append("Supply: %d of max. %d%s" % (supply["level"], supply["max_capacity"], supply["unit"]))
    summary = ", ".join(summary_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {metric_name: pct},
            "details": "",
        },
    }