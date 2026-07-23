def _parse_rated_va(rated_power_str):
    # Parse '43.5kVA' or '4500VA' into VA
    lower_str = rated_power_str.lower()
    if lower_str.find("kva") != -1:
        parts = lower_str.split("kva")
        if len(parts) == 2:
            val_part = parts[0].strip()
            if val_part.replace(".", "").isdigit():
                return float(val_part) * 1000
    elif lower_str.find("va") != -1:
        parts = lower_str.split("va")
        if len(parts) == 2:
            val_part = parts[0].strip()
            if val_part.replace(".", "").isdigit():
                return float(val_part)
    return None


def _clean_snmp_name(value):
    # Strip null bytes and whitespace
    return value.replace("\x00", "").strip()


def _current_reading(amperage_str, device_state):
    # Returns {"value": float, "state": state_text}
    state_map = {
        "1": {"state": "CRIT", "text": "upper critical"},
        "2": {"state": "WARN", "text": "upper warning"},
        "3": {"state": "WARN", "text": "lower warning"},
        "4": {"state": "CRIT", "text": "lower critical"},
        "5": {"state": "OK", "text": "normal"},
    }
    unknown = {"state": "CRIT", "text": "unknown state"}
    state_info = state_map.get(device_state, unknown)
    value = float(amperage_str) / 100.0 if amperage_str.isdigit() or amperage_str.replace(".", "").isdigit() else 0.0
    return {"value": value, "state": state_info["state"], "text": state_info["text"]}


def main(ctx, params):
    # Detect SNMP parameters
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # === DISCOVERY MODE ===
    if params.get("_discover"):
        # Fetch all required SNMP data in one go (multiple snmpwalk calls)
        device_info = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.32.2.2.1.2"
        ], mutates=False)

        device_status = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.32.2.4.1.4",
            ".1.3.6.1.4.1.318.1.1.32.2.4.1.5"
        ], mutates=False)

        n_phases = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.32.3.1"
        ], mutates=False)

        phase_status = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.32.3.4.1.1",
            ".1.3.6.1.4.1.318.1.1.32.3.4.1.3",
            ".1.3.6.1.4.1.318.1.1.32.3.4.1.5",
            ".1.3.6.1.4.1.318.1.1.32.3.4.1.7"
        ], mutates=False)

        bank_status = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.32.4.4.1.3",
            ".1.3.6.1.4.1.318.1.1.32.4.4.1.4",
            ".1.3.6.1.4.1.318.1.1.32.4.4.1.5"
        ], mutates=False)

        phase_config = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.32.3.2.1.1",
            ".1.3.6.1.4.1.318.1.1.32.3.2.1.6",
            ".1.3.6.1.4.1.318.1.1.32.3.2.1.7"
        ], mutates=False)

        device_properties = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.32.2.3.1.13"
        ], mutates=False)

        # Parse phase thresholds: map phase_index -> (warn, crit) in Amps
        phase_thresholds = {}
        phase_index = None
        upper_crit = None
        upper_warn = None
        for line in phase_config.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            val = parts[1].strip()
            if "1.3.6.1.4.1.318.1.1.32.3.2.1.1" in parts[0]:
                if val.startswith("INTEGER:"):
                    phase_index = int(val.split(":")[1].strip())
            elif "1.3.6.1.4.1.318.1.1.32.3.2.1.6" in parts[0]:
                if val.startswith("INTEGER:"):
                    upper_crit = float(val.split(":")[1].strip()) / 100.0
            elif "1.3.6.1.4.1.318.1.1.32.3.2.1.7" in parts[0]:
                if val.startswith("INTEGER:"):
                    upper_warn = float(val.split(":")[1].strip()) / 100.0

            if phase_index != None and upper_crit != None and upper_warn != None:
                phase_thresholds[str(phase_index)] = (upper_warn, upper_crit)
                phase_index = None
                upper_crit = None
                upper_warn = None

        # Parse device info
        pdu_name = ""
        for line in device_info.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                val = parts[1].strip()
                if val.startswith("STRING:"):
                    pdu_name = val.split(":")[1].strip().strip('"')
        pdu_name = _clean_snmp_name(pdu_name)

        # Parse device status: active_power (w), apparent_power (VA)
        device_power = 0.0
        apparent_power = 0.0
        for line in device_status.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            val = parts[1].strip()
            if val.startswith("INTEGER:"):
                num = int(val.split(":")[1].strip())
            elif val.startswith("Gauge32:"):
                num = int(val.split(":")[1].strip())
            else:
                continue
            if ".4" in parts[0]:
                device_power = float(num)
            elif ".5" in parts[0]:
                apparent_power = float(num)

        # Parse rated VA from device_properties
        rated_va = None
        for line in device_properties.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                val = parts[1].strip()
                if val.startswith("STRING:"):
                    raw = val.split(":")[1].strip().strip('"')
                    rated_va = _parse_rated_va(raw)
                    break

        # Calculate total load
        output_load = None
        if rated_va != None and rated_va > 0:
            output_load = apparent_power / rated_va * 100.0

        # Parse n_phases
        n_phase_val = 0
        for line in n_phases.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                val = parts[1].strip()
                if val.startswith("INTEGER:"):
                    n_phase_val = int(val.split(":")[1].strip())
                    break

        # Parse phase status lines
        phase_data = {}
        for line in phase_status.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            val = parts[1].strip()
            if val.startswith("INTEGER:"):
                num = int(val.split(":")[1].strip())
            elif val.startswith("Gauge32:"):
                num = int(val.split(":")[1].strip())
            else:
                continue
            oid_base = parts[0].strip()
            if ".1.3.6.1.4.1.318.1.1.32.3.4.1.1" in oid_base:
                phase_index = str(num)
                phase_data[phase_index] = {}
            elif ".3" in oid_base and phase_index != None:
                phase_data[phase_index]["state"] = str(num)
            elif ".5" in oid_base and phase_index != None:
                phase_data[phase_index]["current"] = str(num)
            elif ".7" in oid_base and phase_index != None:
                phase_data[phase_index]["power"] = str(num)

        # Parse bank status
        bank_data = []
        bank_name = ""
        bank_state = ""
        bank_current = ""
        for line in bank_status.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            val = parts[1].strip()
            oid_base = parts[0].strip()
            if ".1.3.6.1.4.1.318.1.1.32.4.4.1.3" in oid_base:
                if val.startswith("STRING:"):
                    bank_name = val.split(":")[1].strip().strip('"')
            elif ".4" in oid_base:
                if val.startswith("INTEGER:"):
                    bank_state = val.split(":")[1].strip()
                else:
                    continue
            elif ".5" in oid_base:
                if val.startswith("INTEGER:"):
                    bank_current = val.split(":")[1].strip()
                elif val.startswith("Gauge32:"):
                    bank_current = val.split(":")[1].strip()
                else:
                    continue
                if bank_name != "" and bank_name != "NA":
                    bank_data.append({
                        "name": _clean_snmp_name(bank_name),
                        "state": bank_state,
                        "current": bank_current
                    })
                bank_name = ""
                bank_state = ""
                bank_current = ""

        # Build items
        out = []
        # Add device item
        if pdu_name != "":
            device_item = "Device " + pdu_name
            device_phase = None
            if n_phase_val == 1 and len(phase_data) > 0:
                for p_idx, data in phase_data.items():
                    if "state" in data and "current" in data:
                        device_phase = _current_reading(data["current"], data["state"])
                        break

            item = {
                "item": device_item,
                "params": {},
                "metrics": ["power", "output_load"]
            }
            if device_phase != None:
                item["metrics"].append("current")
            out.append(item)

        # Add phase items
        for p_idx, data in phase_data.items():
            item = "Phase " + p_idx
            warn, crit = phase_thresholds.get(p_idx, (None, None))
            item_data = {
                "item": item,
                "params": {},
                "metrics": ["current", "power"]
            }
            if warn != None:
                item_data["params"]["warn_current"] = warn
            if crit != None:
                item_data["params"]["crit_current"] = crit
            out.append(item_data)

        # Add bank items
        for bank in bank_data:
            item = "Bank " + bank["name"]
            out.append({
                "item": item,
                "params": {},
                "metrics": ["current"]
            })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}
        }

    # === CHECK MODE ===
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item name required",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch all SNMP data again
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    device_info = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.32.2.2.1.2"
    ], mutates=False)

    device_status = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.32.2.4.1.4",
        ".1.3.6.1.4.1.318.1.1.32.2.4.1.5"
    ], mutates=False)

    n_phases = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.32.3.1"
    ], mutates=False)

    phase_status = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.32.3.4.1.1",
        ".1.3.6.1.4.1.318.1.1.32.3.4.1.3",
        ".1.3.6.1.4.1.318.1.1.32.3.4.1.5",
        ".1.3.6.1.4.1.318.1.1.32.3.4.1.7"
    ], mutates=False)

    bank_status = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.32.4.4.1.3",
        ".1.3.6.1.4.1.318.1.1.32.4.4.1.4",
        ".1.3.6.1.4.1.318.1.1.32.4.4.1.5"
    ], mutates=False)

    phase_config = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.32.3.2.1.1",
        ".1.3.6.1.4.1.318.1.1.32.3.2.1.6",
        ".1.3.6.1.4.1.318.1.1.32.3.2.1.7"
    ], mutates=False)

    device_properties = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.32.2.3.1.13"
    ], mutates=False)

    # Re-parse data (same logic as discovery, but optimized for single item)
    # Parse device info
    pdu_name = ""
    for line in device_info.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) == 2:
            val = parts[1].strip()
            if val.startswith("STRING:"):
                pdu_name = val.split(":")[1].strip().strip('"')
    pdu_name = _clean_snmp_name(pdu_name)

    # Parse device status
    device_power = 0.0
    apparent_power = 0.0
    for line in device_status.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        val = parts[1].strip()
        if val.startswith("INTEGER:"):
            num = int(val.split(":")[1].strip())
        elif val.startswith("Gauge32:"):
            num = int(val.split(":")[1].strip())
        else:
            continue
        if ".4" in parts[0]:
            device_power = float(num)
        elif ".5" in parts[0]:
            apparent_power = float(num)

    # Parse rated VA
    rated_va = None
    for line in device_properties.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) == 2:
            val = parts[1].strip()
            if val.startswith("STRING:"):
                raw = val.split(":")[1].strip().strip('"')
                rated_va = _parse_rated_va(raw)
                break

    # Parse n_phases
    n_phase_val = 0
    for line in n_phases.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) == 2:
            val = parts[1].strip()
            if val.startswith("INTEGER:"):
                n_phase_val = int(val.split(":")[1].strip())
                break

    # Parse phase thresholds
    phase_thresholds = {}
    phase_index = None
    upper_crit = None
    upper_warn = None
    for line in phase_config.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        val = parts[1].strip()
        if "1.3.6.1.4.1.318.1.1.32.3.2.1.1" in parts[0]:
            if val.startswith("INTEGER:"):
                phase_index = int(val.split(":")[1].strip())
        elif "1.3.6.1.4.1.318.1.1.32.3.2.1.6" in parts[0]:
            if val.startswith("INTEGER:"):
                upper_crit = float(val.split(":")[1].strip()) / 100.0
        elif "1.3.6.1.4.1.318.1.1.32.3.2.1.7" in parts[0]:
            if val.startswith("INTEGER:"):
                upper_warn = float(val.split(":")[1].strip()) / 100.0

        if phase_index != None and upper_crit != None and upper_warn != None:
            phase_thresholds[str(phase_index)] = (upper_warn, upper_crit)
            phase_index = None
            upper_crit = None
            upper_warn = None

    # Parse phase status
    phase_data = {}
    for line in phase_status.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        val = parts[1].strip()
        if val.startswith("INTEGER:"):
            num = int(val.split(":")[1].strip())
        elif val.startswith("Gauge32:"):
            num = int(val.split(":")[1].strip())
        else:
            continue
        oid_base = parts[0].strip()
        if ".1.3.6.1.4.1.318.1.1.32.3.4.1.1" in oid_base:
            phase_index = str(num)
            phase_data[phase_index] = {}
        elif ".3" in oid_base and phase_index != None:
            phase_data[phase_index]["state"] = str(num)
        elif ".5" in oid_base and phase_index != None:
            phase_data[phase_index]["current"] = str(num)
        elif ".7" in oid_base and phase_index != None:
            phase_data[phase_index]["power"] = str(num)

    # Parse bank status
    bank_data = []
    bank_name = ""
    bank_state = ""
    bank_current = ""
    for line in bank_status.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        val = parts[1].strip()
        oid_base = parts[0].strip()
        if ".1.3.6.1.4.1.318.1.1.32.4.4.1.3" in oid_base:
            if val.startswith("STRING:"):
                bank_name = val.split(":")[1].strip().strip('"')
        elif ".4" in oid_base:
            if val.startswith("INTEGER:"):
                bank_state = val.split(":")[1].strip()
            else:
                continue
        elif ".5" in oid_base:
            if val.startswith("INTEGER:"):
                bank_current = val.split(":")[1].strip()
            elif val.startswith("Gauge32:"):
                bank_current = val.split(":")[1].strip()
            else:
                continue
            if bank_name != "" and bank_name != "NA":
                bank_data.append({
                    "name": _clean_snmp_name(bank_name),
                    "state": bank_state,
                    "current": bank_current
                })
            bank_name = ""
            bank_state = ""
            bank_current = ""

    # === Determine which item this is and process accordingly ===
    item_lower = item.lower()
    # Device item
    if item_lower.startswith("device "):
        if pdu_name == "" or ("device " + pdu_name).lower() != item_lower:
            return {
                "changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }

        # Calculate total load
        output_load = None
        if rated_va != None and rated_va > 0:
            output_load = apparent_power / rated_va * 100.0

        # Current reading (only for single-phase)
        current_reading = None
        if n_phase_val == 1 and len(phase_data) > 0:
            for p_idx, data in phase_data.items():
                if "state" in data and "current" in data:
                    current_reading = _current_reading(data["current"], data["state"])
                    break

        # State and metrics
        state = "OK"
        msg_parts = []

        # Power metric
        power = device_power
        msg_parts.append("Power: %f W" % power)
        metrics = {"power": power}

        # Output load
        if output_load != None:
            warn_load = params.get("output_load", (80, 90))
            warn_val = warn_load[0]
            crit_val = warn_load[1]
            if output_load >= crit_val:
                state = "CRIT"
            elif output_load >= warn_val:
                if state != "CRIT":
                    state = "WARN"
            msg_parts.append("Load: %f%%" % output_load)
            metrics["output_load"] = output_load

        # Current metric
        if current_reading != None:
            curr_state = current_reading["state"]
            if curr_state == "CRIT":
                state = "CRIT"
            elif curr_state == "WARN" and state != "CRIT":
                state = "WARN"
            msg_parts.append("Current: %f A" % current_reading["value"])
            metrics["current"] = current_reading["value"]

        return {
            "changed": False,
            "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}
        }

    # Phase item
    elif item_lower.startswith("phase "):
        p_idx = item[6:].strip()  # after "Phase "
        if p_idx == "" or not p_idx.isdigit() or phase_data.get(p_idx) == None:
            return {
                "changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }

        data = phase_data[p_idx]
        if "current" not in data or "state" not in data:
            return {
                "changed": False,
                "msg": "missing data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }

        current_reading = _current_reading(data["current"], data["state"])
        power = float(data.get("power", 0))

        # Thresholds
        warn_current = params.get("warn_current", None)
        crit_current = params.get("crit_current", None)
        if warn_current == None and crit_current == None:
            warn_current, crit_current = phase_thresholds.get(p_idx, (None, None))

        # State evaluation
        state = current_reading["state"]
        if state == "OK":
            # Check thresholds manually if not device-reported
            if warn_current != None:
                if current_reading["value"] >= warn_current:
                    state = "WARN"
            if crit_current != None:
                if current_reading["value"] >= crit_current:
                    state = "CRIT"

        msg_parts = []
        msg_parts.append("Current: %f A" % current_reading["value"])
        msg_parts.append("Power: %f W" % power)
        metrics = {"current": current_reading["value"], "power": power}

        return {
            "changed": False,
            "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}
        }

    # Bank item
    elif item_lower.startswith("bank "):
        bank_name = item[5:].strip()  # after "Bank "
        found_bank = None
        for bank in bank_data:
            if bank["name"].lower() == bank_name.lower():
                found_bank = bank
                break

        if found_bank == None:
            return {
                "changed": False,
                "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }

        current_reading = _current_reading(found_bank["current"], found_bank["state"])
        state = current_reading["state"]

        return {
            "changed": False,
            "msg": "Current: %f A" % current_reading["value"],
            "data": {"state": state, "metrics": {"current": current_reading["value"]}, "details": ""}
        }

    else:
        return {
            "changed": False,
            "msg": "unknown item type: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
