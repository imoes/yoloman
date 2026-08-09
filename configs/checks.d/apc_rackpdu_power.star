# APC RackPdu Power — read-only Starlark check module
# Translated from Checkmk checkmk.apc_rackpdu_power (SNMP-based)

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Probe for the real thing: an APC device responding on the SNMP base.
        ident = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, ".1.3.6.1.4.1.318.1.1.12.1.1.0"
        ], mutates=False)
        if ident.rc != 0 or ident.rc == 127:
            return {"changed": False, "msg": "no APC rack PDU found", "data": {"discovery": []}}

        nphases = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, ".1.3.6.1.4.1.318.1.1.12.2.1.2"
        ], mutates=False)
        if nphases.rc != 0:
            return {"changed": False, "msg": "no APC rack PDU found", "data": {"discovery": []}}

        # Device-level service: PDU <ident name>
        ident_name = ident.stdout.strip()
        device_name = "Device " + ident_name

        # Load table walk: rPDULoadStatusLoad (col .2), rPDULoadStatusLoadState (.3),
        # rPDULoadStatusPhaseNumber (.4), rPDULoadStatusBankNumber (.5) under base .1.3.6.1.4.1.318.1.1.12.2.3.1.1
        base = ".1.3.6.1.4.1.318.1.1.12.2.3.1.1"
        walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, base
        ], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "no APC rack PDU found", "data": {"discovery": []}}

        # Build columns keyed by index suffix
        col_load = {}
        col_state = {}
        col_phase = {}
        col_bank = {}
        col_prefix = base + "."
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            val = line[sp + 1:]
            if not oid.startswith(col_prefix):
                continue
            idx = oid[len(col_prefix):]
            last = oid.rsplit(".", 1)[-1]
            if last == "2":
                col_load[idx] = val
            elif last == "3":
                col_state[idx] = val
            elif last == "4":
                col_phase[idx] = val
            elif last == "5":
                col_bank[idx] = val

        discovery = []
        discovery.append({"item": device_name, "params": {}, "metrics": ["power"]})

        num_phases = 0
        if nphases.stdout.strip().isdigit():
            num_phases = int(nphases.stdout.strip())

        first_done = False
        for idx in sorted(col_load.keys()):
            if num_phases == 1 and not first_done:
                # First entry in a 1-phase device is the device current
                first_done = True
                discovery.append({"item": device_name, "params": {}, "metrics": ["current"]})
                continue
            pnum = col_phase.get(idx, "0")
            bnum = col_bank.get(idx, "0")
            if bnum != "0":
                discovery.append({"item": "Bank " + bnum, "params": {}, "metrics": ["current"]})
            elif pnum != "0":
                discovery.append({"item": "Phase " + pnum, "params": {}, "metrics": ["current"]})

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- CHECK MODE ----
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    ident_name = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.4.1.318.1.1.12.1.1.0"
    ], mutates=False)
    power_str = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.4.1.318.1.1.12.1.16.0"
    ], mutates=False)
    nphases = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, ".1.3.6.1.4.1.318.1.1.12.2.1.2"
    ], mutates=False)

    if ident_name.rc != 0 or power_str.rc != 0 or nphases.rc != 0:
        return {
            "changed": False,
            "msg": "APC rack PDU not reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    device_name = "Device " + ident_name.stdout.strip()
    num_phases = 0
    if nphases.stdout.strip().isdigit():
        num_phases = int(nphases.stdout.strip())
    device_power = float(power_str.stdout.strip()) if _is_number(power_str.stdout.strip()) else 0.0

    if item == device_name:
        # Device-level: report power always; current if single-phase first entry
        base = ".1.3.6.1.4.1.318.1.1.12.2.3.1.1"
        walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, base
        ], mutates=False)
        metrics = {"power": device_power}
        state = "OK"
        details = "Power: %f W" % device_power

        if num_phases == 1 and walk.rc == 0 and walk.stdout.strip() != "":
            first_line = walk.stdout.splitlines()[0]
            sp = first_line.find(" ")
            val = first_line[sp + 1:] if sp >= 0 else ""
            if _is_number(val):
                current = float(val) / 10.0
                metrics["current"] = current
                details += ", Current: %f A" % current

        return {
            "changed": False,
            "msg": details,
            "data": {"state": state, "metrics": metrics, "details": details},
        }

    # Item is a Bank or Phase
    label = ""
    if item.startswith("Bank "):
        label = "Bank"
    elif item.startswith("Phase "):
        label = "Phase"
    else:
        return {
            "changed": False,
            "msg": "unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    target_num = item.split(" ").pop()
    base = ".1.3.6.1.4.1.318.1.1.12.2.3.1.1"
    col_phase = base + ".4"
    col_bank = base + ".5"

    if label == "Bank":
        col_walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, col_bank
        ], mutates=False)
        col_other_walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, col_phase
        ], mutates=False)
    else:
        col_walk = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, col_phase
        ], mutates=False)
        col_walk_other = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, col_bank
        ], mutates=False)

    if col_walk.rc != 0 or col_walk.stdout.strip() == "":
        return {
            "changed": False,
            "msg": item + " not found on PDU",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    found_idx = None
    for line in col_walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        idx = oid.rsplit(".", 1)[-1]
        if val == target_num:
            found_idx = idx
            break

    if found_idx == None:
        return {
            "changed": False,
            "msg": item + " not found on PDU",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    load_oid = base + ".2." + found_idx
    state_oid = base + ".3." + found_idx
    load_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, load_oid
    ], mutates=False)
    state_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv",
        host, state_oid
    ], mutates=False)

    if load_res.rc != 0 or state_res.rc != 0:
        return {
            "changed": False,
            "msg": item + " data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    current = float(load_res.stdout.strip()) / 10.0
    state_code = STATE_MAP.get(state_res.stdout.strip(), (3, "unknown"))[0]
    state_text = STATE_MAP.get(state_res.stdout.strip(), (3, "unknown"))[1]

    if state_code == 0:
        state = "OK"
    elif state_code == 1:
        state = "WARN"
    else:
        state = "CRIT"

    return {
        "changed": False,
        "msg": item + ": %f A, %s" % (current, state_text),
        "data": {
            "state": state,
            "metrics": {"current": current},
            "details": item + ": %f A, %s" % (current, state_text),
        },
    }


def _is_number(s):
    if s == None or s == "":
        return False
    if s[0] in "+-":
        s = s[1:]
    return s.replace(".", "", 1).isdigit()


STATE_MAP = {
    "1": (0, "load normal"),
    "2": (2, "load low"),
    "3": (1, "load near over load"),
    "4": (2, "load over load"),
}