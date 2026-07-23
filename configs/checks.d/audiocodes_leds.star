def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Helper to convert SNMP hex string to LED info
    def from_byte(byte_val, module_index=None):
        hex_part = ""
        if len(byte_val) > 2 and (byte_val[0:2] == "0x" or byte_val[0:2] == "0X"):
            hex_part = byte_val[2:]
        else:
            hex_part = byte_val

        if len(hex_part) == 0:
            last_char = "0"
        else:
            last_char = hex_part[-1].lower()

        if last_char == "1":
            status = "FLASHING"
            color = "NONE"
        elif last_char == "2":
            status = "ON"
            color = "GREEN"
        elif last_char == "3":
            status = "FLASHING"
            color = "GREEN"
        elif last_char == "4":
            status = "ON"
            color = "RED"
        elif last_char == "5":
            status = "FLASHING"
            color = "RED"
        elif last_char == "6":
            status = "ON"
            color = "YELLOW"
        elif last_char == "7":
            status = "FLASHING"
            color = "YELLOW"
        elif last_char == "8":
            status = "ON"
            color = "ORANGE"
        elif last_char == "9":
            status = "FLASHING"
            color = "ORANGE"
        elif last_char == "a":
            status = "ON"
            color = "BLUE"
        elif last_char == "b":
            status = "FLASHING"
            color = "BLUE"
        else:
            status = "UNKNOWN"
            color = "UNKNOWN"

        return {"status": status, "color": color, "module_index": module_index}

    # Probe each SNMP tree (using snmpget, not snmpwalk, for reliability)
    def get_snmp(oid):
        res = ctx.run(["snmpget", "-On", "-OvQ", "-c", "public", "localhost", oid], mutates=False)
        if res.rc != 0:
            return ""
        line = res.stdout.strip()
        if line.find(" = ") == -1:
            return ""
        val = line.split(" = ", 1)[1].strip()
        if val == "NoSuchObject" or val == "NoSuchInstance":
            return ""
        return val

    # Module LEDs
    module_base = ".1.3.6.1.4.1.5003.9.10.10.4.21.1"
    module_leds_raw = []
    for i in range(1, 21):
        oid = module_base + "." + str(i) + ".10"
        val = get_snmp(oid)
        if val != "":
            module_leds_raw.append((str(i), val))

    # Fan tray
    fan_base = ".1.3.6.1.4.1.5003.9.10.10.4.22.1"
    fan_tray_raw = []
    for i in range(1, 11):
        oid_led = fan_base + "." + str(i) + ".5"
        oid_desc = fan_base + "." + str(i) + ".4"
        val_led = get_snmp(oid_led)
        val_desc = get_snmp(oid_desc)
        if val_led != "":
            fan_tray_raw.append((str(i), val_led, val_desc))

    # Power supply
    ps_base = ".1.3.6.1.4.1.5003.9.10.10.4.23.1"
    ps_raw = []
    for i in range(1, 6):
        oid = ps_base + "." + str(i) + ".5"
        val = get_snmp(oid)
        if val != "":
            ps_raw.append((str(i), val))

    # Redundant fan tray
    rfan_base = ".1.3.6.1.4.1.5003.9.10.10.4.27.22.1"
    rfan_raw = []
    for i in range(1, 6):
        oid_led = rfan_base + "." + str(i) + ".5"
        oid_desc = rfan_base + "." + str(i) + ".4"
        val_led = get_snmp(oid_led)
        val_desc = get_snmp(oid_desc)
        if val_led != "":
            rfan_raw.append((str(i), val_led, val_desc))

    # Redundant power supply
    rps_base = ".1.3.6.1.4.1.5003.9.10.10.4.27.23.1"
    rps_raw = []
    for i in range(1, 6):
        oid = rps_base + "." + str(i) + ".5"
        val = get_snmp(oid)
        if val != "":
            rps_raw.append((str(i), val))

    all_leds = []

    # Module LEDs: no name, use module_index
    for idx, byte_val in module_leds_raw:
        led = from_byte(byte_val, module_index=idx)
        all_leds.append({"name": None, "status": led["status"], "color": led["color"], "module_index": led["module_index"]})

    # Fan tray
    for idx, byte_val, desc in fan_tray_raw:
        led = from_byte(byte_val)
        name = desc if desc != "" else "(unnamed fan tray)"
        all_leds.append({"name": name, "status": led["status"], "color": led["color"], "module_index": None})

    # Power supply
    for idx, byte_val in ps_raw:
        led = from_byte(byte_val)
        name = "Power supply " + str(idx)
        all_leds.append({"name": name, "status": led["status"], "color": led["color"], "module_index": None})

    # Redundant fan tray
    for idx, byte_val, desc in rfan_raw:
        led = from_byte(byte_val)
        name = desc + " (redundant)" if desc != "" else "Fan tray " + str(idx) + " (redundant)"
        all_leds.append({"name": name, "status": led["status"], "color": led["color"], "module_index": None})

    # Redundant power supply
    for idx, byte_val in rps_raw:
        led = from_byte(byte_val)
        name = "Power supply " + str(idx) + " (redundant)"
        all_leds.append({"name": name, "status": led["status"], "color": led["color"], "module_index": None})

    if len(all_leds) == 0:
        return {
            "changed": False,
            "msg": "no LED data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Aggregate results
    color_counts = {"GREEN": 0, "RED": 0, "YELLOW": 0, "ORANGE": 0, "BLUE": 0, "NONE": 0, "UNKNOWN": 0}
    details_lines = []
    max_state = 0  # 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN

    def state_for_color(color):
        if color == "GREEN":
            return 0
        elif color == "RED":
            return 2
        elif color == "YELLOW" or color == "ORANGE" or color == "BLUE":
            return 1
        else:
            return 3

    for led in all_leds:
        color = led["color"]
        if color in color_counts:
            color_counts[color] = color_counts[color] + 1
        state_int = state_for_color(color)
        if state_int > max_state:
            max_state = state_int

        name = led["name"]
        if name == None and led["module_index"] != None:
            name = "(unknown module " + str(led["module_index"]) + ")"
        elif name == None:
            name = "(unnamed LED)"

        details_lines.append(name + " LED: " + led["status"] + "-" + led["color"])

    # Final state
    state_map = ["OK", "WARN", "CRIT", "UNKNOWN"]
    state = state_map[max_state]

    # Build message
    msg_parts = []
    for color in ["GREEN", "RED", "YELLOW", "ORANGE", "BLUE", "NONE", "UNKNOWN"]:
        count = color_counts[color]
        if count > 0:
            plural = "" if count == 1 else "s"
            msg_parts.append(str(count) + " " + color.lower() + " LED" + plural)
    msg = ", ".join(msg_parts) if len(msg_parts) > 0 else "no LEDs detected"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "; ".join(details_lines),
        },
    }
