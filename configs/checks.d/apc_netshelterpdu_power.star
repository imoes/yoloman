# Translated Checkmk check: apc_netshelterpdu_power (APC NetShelter APDU via SNMP)
# READ-ONLY Starlark check module. Probes a real PDU over SNMP.

def _clean_name(value):
    return value.replace("\x00", "").strip()


def _parse_rated_va(rated_power_str):
    s = rated_power_str.strip().upper()
    if s.endswith("KVA"):
        num = s[:-3].strip()
        if num.replace(".", "", 1).isdigit():
            return float(num) * 1000
        return None
    if s.endswith("VA"):
        num = s[:-2].strip()
        if num.replace(".", "", 1).isdigit():
            return float(num)
        return None
    return None


def _current_reading(amperage_str, device_state):
    val = 0.0
    if amperage_str != None and amperage_str != "":
        val = float(amperage_str) / 100.0
    state_map = {
        1: "CRIT",
        2: "WARN",
        3: "WARN",
        4: "CRIT",
        5: "OK",
    }
    ds = int(device_state) if (device_state != None and device_state.strip().isdigit()) else 0
    st = state_map.get(ds, "UNKNOWN")
    return val, st


def _grade_upper(value, warn, crit):
    if value == None:
        return "OK"
    if warn != None and value >= warn:
        if crit != None and value >= crit:
            return "CRIT"
        return "WARN"
    return "OK"


def _grade_lower(value, warn, crit):
    if value == None:
        return "OK"
    if warn != None and value <= warn:
        if crit != None and value <= crit:
            return "CRIT"
        return "WARN"
    return "OK"


def _snmp_get_lines(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-m", "", oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        idx = line.find(" ")
        if idx == -1:
            continue
        out.append((line[:idx], line[idx + 1:]))
    return out


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", "-m", "", oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _probe_pdu(ctx, host, community):
    """Probe a real APC NetShelter PDU via SNMP. Returns None if not a PDU."""
    sys_obj = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sys_obj == None:
        return None
    if not sys_obj.startswith(".1.3.6.1.4.1.318.1.1.32"):
        return None

    device_info = _snmp_get(ctx, host, community, ".1.3.6.1.4.1.318.1.1.32.2.2.1.2")
    device_status = _snmp_get_lines(ctx, host, community, ".1.3.6.1.4.1.318.1.1.32.2.4.1")
    n_phases_str = _snmp_get(ctx, host, community, ".1.3.6.1.4.1.318.1.1.32.3.1")
    phase_status = _snmp_get_lines(ctx, host, community, ".1.3.6.1.4.1.318.1.1.32.3.4.1")
    bank_status = _snmp_get_lines(ctx, host, community, ".1.3.6.1.4.1.318.1.1.32.4.4.1")
    phase_config = _snmp_get_lines(ctx, host, community, ".1.3.6.1.4.1.318.1.1.32.3.2.1")
    device_properties = _snmp_get_lines(ctx, host, community, ".1.3.6.1.4.1.318.1.1.32.2.3.1")

    # Build threshold map: phase_index -> {warn, crit} in Amps
    base_phase_cfg = ".1.3.6.1.4.1.318.1.1.32.3.2.1"
    phase_thresholds = {}
    for oid, val in phase_config:
        suffix = oid[len(base_phase_cfg):]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col = parts[0]
        idx = parts[1]
        entry = phase_thresholds.get(idx, {"warn": None, "crit": None})
        fval = float(val) / 100.0
        if col == "6":
            entry["crit"] = fval
        elif col == "7":
            entry["warn"] = fval
        phase_thresholds[idx] = entry

    n_phases = None
    if n_phases_str != None and n_phases_str.strip().isdigit():
        n_phases = int(n_phases_str.strip())

    # Device-level power and apparent power
    device_power = None
    apparent_power = None
    base_dev_status = ".1.3.6.1.4.1.318.1.1.32.2.4.1"
    for oid, val in device_status:
        suffix = oid[len(base_dev_status):]
        if suffix == ".4":
            device_power = float(val)
        elif suffix == ".5":
            apparent_power = float(val)

    pdu_name = _clean_name(device_info) if device_info != None else None
    device_name = "Device " + pdu_name if pdu_name != None else None

    rated_va = None
    base_dev_props = ".1.3.6.1.4.1.318.1.1.32.2.3.1"
    for oid, val in device_properties:
        suffix = oid[len(base_dev_props):]
        if suffix == ".13":
            rated_va = _parse_rated_va(val)

    # Reassemble phase_status rows by index
    base_phase = ".1.3.6.1.4.1.318.1.1.32.3.4.1"
    phase_rows = {}
    for oid, val in phase_status:
        suffix = oid[len(base_phase):]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col = parts[0]
        idx = parts[1]
        row = phase_rows.get(idx, {"state": None, "current": None, "power": None})
        if col == "1":
            row["state"] = val
        elif col == "3":
            row["current"] = val
        elif col == "5":
            row["power"] = val
        phase_rows[idx] = row

    # Device-level current for single-phase PDU
    device_current = None
    if n_phases != None and n_phases == 1 and "1" in phase_rows:
        rw = phase_rows["1"]
        device_current = _current_reading(rw.get("current", ""), rw.get("state", ""))

    items = {}

    if device_name != None:
        output_load = None
        if rated_va != None and rated_va > 0 and apparent_power != None:
            output_load = apparent_power / rated_va * 100.0
        items[device_name] = {
            "power": device_power,
            "current": device_current,
            "output_load": output_load,
            "warn_current": None,
            "crit_current": None,
        }

    # Phase items
    for idx, rw in phase_rows.items():
        th = phase_thresholds.get(idx, {"warn": None, "crit": None})
        cur_val, cur_st = _current_reading(rw.get("current", ""), rw.get("state", ""))
        pw = None
        if rw.get("power") != None and rw.get("power") != "":
            pw = float(rw.get("power"))
        items["Phase " + idx] = {
            "power": pw,
            "current": (cur_val, cur_st),
            "output_load": None,
            "warn_current": th.get("warn"),
            "crit_current": th.get("crit"),
        }

    # Bank items: reassemble by index, col 3=name, 4=state, 5=current
    base_bank = ".1.3.6.1.4.1.318.1.1.32.4.4.1"
    bank_rows = {}
    bank_names = {}
    for oid, val in bank_status:
        suffix = oid[len(base_bank):]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col = parts[0]
        idx = parts[1]
        if col == "3":
            bank_names[idx] = _clean_name(val)
        row = bank_rows.get(idx, {"name": None, "state": None, "current": None})
        if col == "4":
            row["state"] = val
        elif col == "5":
            row["current"] = val
        bank_rows[idx] = row

    for idx, row in bank_rows.items():
        bname = bank_names.get(idx, "")
        if bname == "NA" or bname == "":
            continue
        cur_val, cur_st = _current_reading(row.get("current", ""), row.get("state", ""))
        items["Bank " + bname] = {
            "power": None,
            "current": (cur_val, cur_st),
            "output_load": None,
            "warn_current": None,
            "crit_current": None,
        }

    if not items:
        return None
    return items, device_name, n_phases


def _check_item(item, entry, params):
    """Grade one PDU item. Returns (state, msg, metrics)."""
    warn = params.get("warn")
    crit = params.get("crit")

    metrics = {}
    states = []

    cur = entry.get("current")
    if type(cur) == "tuple":
        cur_val, cur_st = cur
        if cur_val != None:
            metrics["current"] = cur_val
        if cur_st != "OK" and cur_st != None:
            states.append(cur_st)
        w = warn if warn != None else entry.get("warn_current")
        c = crit if crit != None else entry.get("crit_current")
        if w != None or c != None:
            g = _grade_upper(cur_val, w, c) if cur_val != None else "OK"
            if g != "OK":
                states.append(g)

    pw = entry.get("power")
    if pw != None:
        metrics["power"] = pw

    ol = entry.get("output_load")
    if ol != None:
        metrics["output_load"] = ol
        lw = params.get("output_load_warn", 80)
        lc = params.get("output_load_crit", 90)
        g = _grade_upper(ol, lw, lc)
        if g != "OK":
            states.append(g)

    final = "OK"
    for s in states:
        if s == "CRIT":
            final = "CRIT"
        elif s == "WARN" and final != "CRIT":
            final = "WARN"
        elif s == "UNKNOWN" and final == "OK":
            final = "UNKNOWN"

    if final == "UNKNOWN":
        msg = "no usable SNMP data for " + item
    else:
        parts = []
        if pw != None:
            parts.append("Power: %f W" % pw)
        if type(cur) == "tuple" and cur[0] != None:
            parts.append("Current: %f A" % cur[0])
        if ol != None:
            parts.append("Load: %f%%" % ol)
        if not parts:
            msg = item + " " + final
        else:
            msg = item + " - " + ", ".join(parts)

    return final, msg, metrics


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        probed = _probe_pdu(ctx, host, community)
        if probed == None:
            return {"changed": False, "msg": "no APC NetShelter PDU found via SNMP",
                    "data": {"discovery": []}}
        items, device_name, n_phases = probed
        discovery = []
        for item in sorted(items.keys()):
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["current", "power", "output_load"],
            })
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    probed = _probe_pdu(ctx, host, community)
    if probed == None:
        return {"changed": False, "msg": "no APC NetShelter PDU found via SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    items, device_name, n_phases = probed
    entry = items.get(item)
    if entry == None:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state, msg, metrics = _check_item(item, entry, params)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}