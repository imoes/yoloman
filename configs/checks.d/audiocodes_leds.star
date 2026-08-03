# AudioCodes LED Status check for the yolo-man agent.
# Translated from Checkmk's checkmk.audiocodes_leds (an SNMP-based check).

# OID bases (AudioCodes enterprise .1.3.6.1.4.1.5003 -> .9.10.10.4 ...).
MODULE_LED_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.21.1"
FAN_TRAY_LED_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.22.1"
POWER_LED_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.23.1"
REDUNDANT_FAN_LED_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.27.22.1"
REDUNDANT_POWER_LED_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.27.23.1"
MODULE_NAMES_BASE = ".1.3.6.1.4.1.5003.9.10.10.4.20.1"

# Map of the low-nibble hex digits produced by LED.from_byte to
# (status, color).
_LED_MAP = {
    "1": ("FLASHING", "NONE"),
    "2": ("ON", "GREEN"),
    "3": ("FLASHING", "GREEN"),
    "4": ("ON", "RED"),
    "5": ("FLASHING", "RED"),
    "6": ("ON", "YELLOW"),
    "7": ("FLASHING", "YELLOW"),
    "8": ("ON", "ORANGE"),
    "9": ("FLASHING", "ORANGE"),
    "a": ("ON", "BLUE"),
    "b": ("FLASHING", "BLUE"),
}

# Column indices within the fan/power tables.
LED_BYTE_COL = "5"
LED_DESC_COL = "4"


def _led_from_byte(name, byte_str, module_index):
    """Reproduce LED.from_byte. Returns (status, color, name, module_index)."""
    if byte_str == None or len(byte_str) == 0:
        return ("UNKNOWN", "UNKNOWN", name, module_index)
    nibble = "%x" % ord(byte_str[0])
    if len(nibble) > 1:
        nibble = nibble[-1]
    status, color = _LED_MAP.get(nibble, ("UNKNOWN", "UNKNOWN"))
    return (status, color, name, module_index)


def _led_state(color):
    """Map a color to the Checkmk state string (mirrors LED.to_state)."""
    if color == "GREEN":
        return "OK"
    if color == "RED":
        return "CRIT"
    if color in ("YELLOW", "ORANGE", "BLUE"):
        return "WARN"
    return "UNKNOWN"


def _snmp_get_byte(ctx, host, community, oid):
    """Fetch a single scalar OID, return the bare value via -Oqv."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk_column(ctx, host, community, base, col):
    """Walk a single column of an SNMP table.

    Returns a dict: index_suffix -> bare value.
    """
    col_oid = base + "." + col
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
        mutates=False,
    )
    out = {}
    if res.rc != 0 or not res.stdout.strip():
        return out
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:].strip()
        if full_oid.startswith(col_oid + "."):
            idx = full_oid[len(col_oid) + 1:]
            out[idx] = value
    return out


def _module_names(ctx, host, community):
    """Fetch module-index -> name mapping from the module names table."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, MODULE_NAMES_BASE],
        mutates=False,
    )
    names = {}
    if res.rc != 0 or not res.stdout.strip():
        return names
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:].strip()
        if full_oid.startswith(MODULE_NAMES_BASE + "."):
            idx = full_oid[len(MODULE_NAMES_BASE) + 1:]
            names[idx] = value
    return names


def _gather_leds(ctx, host, community):
    """Reproduce parse_audiocodes_leds: fetch all LED tables and decode LEDs."""
    module_names = _module_names(ctx, host, community)

    module_leds = []
    fan_tray_leds = []
    power_supply_leds = []
    redundant_fan_tray_leds = []
    redundant_power_supply_leds = []

    # module LEDs: base has OIDEnd() index + column "10" (the byte).
    module_bytes = _snmp_walk_column(ctx, host, community, MODULE_LED_BASE, LED_BYTE_COL)
    for idx, byte_val in module_bytes.items():
        led = _led_from_byte(None, byte_val, idx)
        module_leds.append(led)

    # fan tray: column 5 = LED byte, column 4 = description.
    fan_desc = _snmp_walk_column(ctx, host, community, FAN_TRAY_LED_BASE, LED_DESC_COL)
    fan_byte = _snmp_walk_column(ctx, host, community, FAN_TRAY_LED_BASE, LED_BYTE_COL)
    for idx, desc in fan_desc.items():
        byte_val = fan_byte.get(idx, "")
        led = _led_from_byte(desc, byte_val)
        fan_tray_leds.append(led)

    # power supply: column 5 = LED byte, index = supply id.
    power_byte = _snmp_walk_column(ctx, host, community, POWER_LED_BASE, LED_BYTE_COL)
    for idx, byte_val in power_byte.items():
        led = _led_from_byte("Power supply %s" % idx, byte_val)
        power_supply_leds.append(led)

    # redundant fan tray: column 4 = description, column 5 = LED byte.
    rfan_desc = _snmp_walk_column(ctx, host, community, REDUNDANT_FAN_LED_BASE, LED_DESC_COL)
    rfan_byte = _snmp_walk_column(ctx, host, community, REDUNDANT_FAN_LED_BASE, LED_BYTE_COL)
    for idx, desc in rfan_desc.items():
        byte_val = rfan_byte.get(idx, "")
        led = _led_from_byte("%s (redundant)" % desc, byte_val)
        redundant_fan_tray_leds.append(led)

    # redundant power supply: column 5 = LED byte, index = supply id.
    rpower_byte = _snmp_walk_column(ctx, host, community, REDUNDANT_POWER_LED_BASE, LED_BYTE_COL)
    for idx, byte_val in rpower_byte.items():
        led = _led_from_byte("Power supply %s (redundant)" % idx, byte_val)
        redundant_power_supply_leds.append(led)

    return {
        "module_leds": module_leds,
        "fan_tray_leds": fan_tray_leds,
        "power_supply_leds": power_supply_leds,
        "redundant_fan_tray_leds": redundant_fan_tray_leds,
        "redundant_power_supply_leds": redundant_power_supply_leds,
        "module_names": module_names,
    }


def _resolve_name(name, module_index, module_names):
    if name != None:
        return name
    if module_index != None and module_index in module_names:
        return module_names[module_index]
    return "(unknown module)"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe that this is really an AudioCodes device first.
        sys_oid = _snmp_get_byte(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if sys_oid == None or not sys_oid.lower().startswith(".1.3.6.1.4.1.5003"):
            return {
                "changed": False,
                "msg": "no AudioCodes device found",
                "data": {"discovery": [], "host_labels": {}},
            }
        led_data = _gather_leds(ctx, host, community)
        if (
            not led_data["module_leds"]
            and not led_data["fan_tray_leds"]
            and not led_data["power_supply_leds"]
            and not led_data["redundant_fan_tray_leds"]
            and not led_data["redundant_power_supply_leds"]
        ):
            return {
                "changed": False,
                "msg": "no LEDs discovered",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 LED status service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["led_ok", "led_warn", "led_crit", "led_unknown"],
                    }
                ],
                "host_labels": {"cmk/vendor": "audiocodes"},
            },
        }

    # ---- CHECK MODE ----
    led_data = _gather_leds(ctx, host, community)

    all_leds = list(
        led_data["module_leds"]
        + led_data["fan_tray_leds"]
        + led_data["power_supply_leds"]
        + led_data["redundant_fan_tray_leds"]
        + led_data["redundant_power_supply_leds"]
    )

    if not all_leds:
        return {
            "changed": False,
            "msg": "no LED information available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    color_counts = {}
    worst = "OK"
    details = []
    for status, color, name, module_index in all_leds:
        n = _resolve_name(name, module_index, led_data["module_names"])
        st = _led_state(color)
        details.append("%s LED: %s-%s" % (n, status, color))
        color_counts[color] = color_counts.get(color, 0) + 1
        if st == "CRIT":
            worst = "CRIT"
        elif st == "WARN" and worst != "CRIT":
            worst = "WARN"
        elif st == "UNKNOWN" and worst == "OK":
            worst = "UNKNOWN"

    summary_parts = []
    for color in ("GREEN", "RED", "YELLOW", "ORANGE", "BLUE", "NONE", "UNKNOWN"):
        count = color_counts.get(color, 0)
        if count > 0:
            summary_parts.append("%d %s LED%s" % (count, color, "" if count == 1 else "s"))
    summary = ", ".join(summary_parts)

    metrics = {}
    for color in ("GREEN", "RED", "YELLOW", "ORANGE", "BLUE", "NONE", "UNKNOWN"):
        metrics["led_" + color.lower()] = color_counts.get(color, 0)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": worst,
            "metrics": metrics,
            "details": "\n".join(details),
        },
    }