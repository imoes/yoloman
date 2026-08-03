# cisco_ucs_mem - read-only Checkmk SNMP memory-unit check (translated to Starlark)
# Source: cmk/plugins/cisco/agent_based/cisco_ucs_mem.py + lib_ucs
# Data source: net-snmp (snmpget/snmpwalk) against the host's Cisco UCS OIDs.
# READ-ONLY: no mutates=True, no ctx.file_write, changed=False always.

MEM_BASE = ".1.3.6.1.4.1.9.9.719.1.30.11.1"
MEM_COLS = ["3", "19", "23", "6", "14", "17", "2"]

MAP_OPERABILITY = {
    "0": (2, "unknown"), "1": (0, "operable"), "2": (2, "inoperable"), "3": (2, "degraded"),
    "4": (1, "poweredOff"), "5": (2, "powerProblem"), "6": (0, "removed"), "7": (2, "voltageProblem"),
    "8": (2, "thermalProblem"), "9": (1, "performanceProblem"), "10": (1, "accessibilityProblem"),
    "11": (1, "identityUnestablishable"), "12": (2, "biosPostTimeout"), "13": (1, "disabled"),
    "14": (1, "malformedFru"), "51": (1, "fabricConnProblem"), "52": (1, "fabricUnsupportedConn"),
    "81": (1, "config"), "82": (2, "equipmentProblem"), "83": (2, "decomissioning"),
    "84": (1, "chassisLimitExceeded"), "100": (1, "notSupported"), "101": (1, "discovery"),
    "102": (2, "discoveryFailed"), "103": (1, "identify"), "104": (2, "postFailure"),
    "105": (1, "upgradeProblem"), "106": (1, "peerCommProblem"), "107": (0, "autoUpgrade"),
    "108": (1, "linkActivateBlocked"),
}

MAP_PRESENCE = {
    "0": (1, "unknown"), "1": (0, "empty"), "10": (0, "equipped"), "11": (0, "missing"),
    "12": (1, "mismatch"), "13": (0, "equippedNotPrimary"), "14": (0, "equippedSlave"),
    "15": (1, "mismatchSlave"), "16": (1, "missingSlave"), "20": (1, "equippedIdentityUnestablishable"),
    "21": (1, "mismatchIdentityUnestablishable"), "22": (1, "equippedWithMalformedFru"),
    "30": (1, "inaccessible"), "40": (1, "unauthorized"), "100": (1, "notSupported"),
    "101": (1, "equippedUnsupported"), "102": (1, "equippedDiscNotStarted"), "103": (0, "equippedDiscInProgress"),
    "104": (2, "equippedDiscError"), "105": (1, "equippedDiscUnknown"),
}

MEMTYPE_NAMES = {
    "0": "undiscovered", "1": "other", "2": "unknown", "3": "dram", "4": "edram", "5": "vram",
    "6": "sram", "7": "ram", "8": "rom", "9": "flash", "10": "eeprom", "11": "feprom",
    "12": "eprom", "13": "cdram", "14": "n3DRAM", "15": "sdram", "16": "sgram", "17": "rdram",
    "18": "ddr", "19": "ddr2", "20": "ddr2FbDimm", "24": "ddr3", "25": "fbd2", "26": "ddr4",
}

LEVEL_TO_STATE = {0: "OK", 1: "WARN", 2: "CRIT"}


def _state_from_level(level):
    return LEVEL_TO_STATE.get(level, "UNKNOWN")


def _strip_quotes(val):
    v = val
    if len(v) >= 2 and v[0] == '"' and v[len(v) - 1] == '"':
        return v[1:len(v) - 1]
    return v


def _fetch_row(ctx, host, community, cols, index):
    row = []
    for col in cols:
        oid = MEM_BASE + "." + col + "." + index
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if res.rc == 0:
            row.append(_strip_quotes(res.stdout.strip()))
        else:
            row.append("")
    return row


def _walk_indices(ctx, host, community, index_col):
    col_oid = MEM_BASE + "." + index_col
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return []
    indices = []
    prefix = col_oid + "."
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        if oid.startswith(prefix):
            idx = oid[len(prefix):]
            if idx:
                indices.append(idx)
    return indices


def _discover_cisco_ucs_mem(ctx, host, community):
    indices = _walk_indices(ctx, host, community, "2")
    if len(indices) == 0:
        return []
    discovery = []
    seen = {}
    for idx in indices:
        row = _fetch_row(ctx, host, community, MEM_COLS, idx)
        if len(row) < 7:
            continue
        dn = row[6]
        presence_code = row[5]
        pres_entry = MAP_PRESENCE.get(presence_code)
        if pres_entry == None:
            continue
        _, presence_name = pres_entry
        if presence_name == "missing":
            continue
        if dn == "" or seen.get(dn, False):
            continue
        seen[dn] = True
        discovery.append({"item": dn, "params": {}, "metrics": []})
    return discovery


def _check_cisco_faults(ctx, host, community, item):
    fault_oid = MEM_BASE + ".7"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, fault_oid], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return "OK", "No faults"
    msgs = []
    for line in res.stdout.splitlines():
        s = line.strip()
        if s and not msgs.count(s):
            msgs.append(s)
    detail = "Faults: " + "; ".join(msgs)
    return "WARN", detail


def _check_one(ctx, host, community, item):
    if item == "":
        return {"changed": False, "msg": "no memory unit selected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    row = _fetch_row(ctx, host, community, MEM_COLS, item)
    if len(row) < 7:
        return {"changed": False, "msg": "memory unit not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    rn = row[0]
    serial = row[1]
    memtype_code = row[2]
    capacity = row[3]
    operability_code = row[4]
    presence_code = row[5]
    dn = row[6]

    oper_entry = MAP_OPERABILITY.get(operability_code, (2, "unknown"))
    pres_entry = MAP_PRESENCE.get(presence_code, (1, "unknown"))
    oper_level = oper_entry[0]
    oper_name = oper_entry[1]
    pres_level = pres_entry[0]
    pres_name = pres_entry[1]
    memtype_name = MEMTYPE_NAMES.get(memtype_code, "unknown")

    levels = [oper_level, pres_level]
    max_level = max(levels) if len(levels) > 0 else 2

    msg_parts = []
    msg_parts.append("Operability: " + oper_name)
    msg_parts.append("Presence: " + pres_name)
    msg_parts.append("Type: " + memtype_name)
    msg_parts.append("Size: " + capacity + " MB, SN: " + serial)

    fault_state, fault_detail = _check_cisco_faults(ctx, host, community, item)
    fault_level = 1 if fault_state == "WARN" else (2 if fault_state == "CRIT" else 0)
    if fault_level > max_level:
        max_level = fault_level

    state = _state_from_level(max_level)
    details = "\n".join(msg_parts)
    if fault_state != "OK":
        details = details + "\n" + fault_detail

    return {"changed": False, "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {}, "details": details}}


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        probe = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, MEM_BASE + ".2"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"discovery": []}}
        if probe.rc != 0 or not probe.stdout.strip():
            return {"changed": False, "msg": "no cisco_ucs_mem data (no memory units)",
                    "data": {"discovery": []}}
        discovery = _discover_cisco_ucs_mem(ctx, host, community)
        return {"changed": False, "msg": "discovered %d memory units" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    return _check_one(ctx, host, community, item)