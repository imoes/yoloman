# Module: cisco_ucs_mem
# Translate Checkmk check: checkmk.cisco_ucs_mem (read-only SNMP check)

# MemoryType mapping (same as source enum + State.OK for all types)
MEMORY_TYPES = {
    "0": "undiscovered",
    "1": "other",
    "2": "unknown",
    "3": "dram",
    "4": "edram",
    "5": "vram",
    "6": "sram",
    "7": "ram",
    "8": "rom",
    "9": "flash",
    "10": "eeprom",
    "11": "feprom",
    "12": "eprom",
    "13": "cdram",
    "14": "n3DRAM",
    "15": "sdram",
    "16": "sgram",
    "17": "rdram",
    "18": "ddr",
    "19": "ddr2",
    "20": "ddr2FbDimm",
    "24": "ddr3",
    "25": "fbd2",
    "26": "ddr4",
}

# Operability mapping: code -> (State, name)
# State mapping: 0=OK, 1=WARN, 2=CRIT (per source MAP_OPERABILITY)
OPERABILITY_MAP = {
    "0": (2, "unknown"),
    "1": (0, "operable"),
    "2": (2, "inoperable"),
    "3": (2, "degraded"),
    "4": (1, "poweredOff"),
    "5": (2, "powerProblem"),
    "6": (0, "removed"),
    "7": (2, "voltageProblem"),
    "8": (2, "thermalProblem"),
    "9": (1, "performanceProblem"),
    "10": (1, "accessibilityProblem"),
    "11": (1, "identityUnestablishable"),
    "12": (2, "biosPostTimeout"),
    "13": (1, "disabled"),
    "14": (1, "malformedFru"),
    "51": (1, "fabricConnProblem"),
    "52": (1, "fabricUnsupportedConn"),
    "81": (1, "config"),
    "82": (2, "equipmentProblem"),
    "83": (2, "decomissioning"),
    "84": (1, "chassisLimitExceeded"),
    "100": (1, "notSupported"),
    "101": (1, "discovery"),
    "102": (2, "discoveryFailed"),
    "103": (1, "identify"),
    "104": (2, "postFailure"),
    "105": (1, "upgradeProblem"),
    "106": (1, "peerCommProblem"),
    "107": (0, "autoUpgrade"),
    "108": (1, "linkActivateBlocked"),
}

# Presence mapping: code -> (State, name)
# State mapping: 0=OK, 1=WARN, 2=CRIT (per source MAP_PRESENCE)
PRESENCE_MAP = {
    "0": (1, "unknown"),
    "1": (0, "empty"),
    "10": (0, "equipped"),
    "11": (0, "missing"),
    "12": (1, "mismatch"),
    "13": (0, "equippedNotPrimary"),
    "14": (0, "equippedSlave"),
    "15": (1, "mismatchSlave"),
    "16": (1, "missingSlave"),
    "20": (1, "equippedIdentityUnestablishable"),
    "21": (1, "mismatchIdentityUnestablishable"),
}


def _get_state_for_operability(oper_code):
    state_idx = OPERABILITY_MAP.get(oper_code, (2, "unknown"))[0]
    return state_idx


def _get_state_for_presence(pres_code):
    state_idx = PRESENCE_MAP.get(pres_code, (1, "unknown"))[0]
    return state_idx


def _state_to_str(state_idx):
    if state_idx == 0:
        return "OK"
    elif state_idx == 1:
        return "WARN"
    elif state_idx == 2:
        return "CRIT"
    else:
        return "UNKNOWN"


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # SNMP base OID for cisco_ucs_mem
    base_oid = ".1.3.6.1.4.1.9.9.719.1.30.11.1"

    # Helper to parse snmpwalk output
    def parse_snmp_output(lines):
        # Each line: OID = STRING: value
        # Group by Dn (cucsMemoryUnitDn, OID index 6 -> .1.3.6.1.4.1.9.9.719.1.30.11.1.2)
        # We'll parse into a list of records: [ (rn, serial, type, capacity, oper, presence, dn) ]
        entries = []
        for line in lines:
            if not line.strip():
                continue
            # Parse "OID = TYPE: value"
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            value_part = line[eq_idx + 1:].strip()
            # Remove leading dots from OID to get relative part
            if oid_part.startswith("."):
                oid_part = oid_part[1:]
            # Split value type and string
            colon_idx = value_part.find(": ")
            if colon_idx == -1:
                continue
            value = value_part[colon_idx + 2:].strip()
            entries.append((oid_part, value))
        # Now group by index: we need to reconstruct rows.
        # OIDs:
        #   .1.3.6.1.4.1.9.9.719.1.30.11.1.3  -> index: 3  (rn)
        #   .1.3.6.1.4.1.9.9.719.1.30.11.1.19 -> index: 19 (serial)
        #   .1.3.6.1.4.1.9.9.719.1.30.11.1.23 -> index: 23 (type)
        #   .1.3.6.1.4.1.9.9.719.1.30.11.1.6  -> index: 6  (capacity)
        #   .1.3.6.1.4.1.9.9.719.1.30.11.1.14 -> index: 14 (operability)
        #   .1.3.6.1.4.1.9.9.719.1.30.11.1.17 -> index: 17 (presence)
        #   .1.3.6.1.4.1.9.9.719.1.30.11.1.2  -> index: 2  (dn)
        # Extract the index suffix: e.g., ".3" -> 3, ".19" -> 19
        # Build map: dn_index -> list of (rn, serial, type, capacity, oper, presence)
        # Since snmpwalk returns entries in order, we can use the index part after base OID
        # But easier: use the numeric OID after base_oid (without .1.3.6.1.4.1.9.9.719.1.30.11.1.)
        # We'll use a dict keyed by the index after base_oid
        # Example: for ".1.3.6.1.4.1.9.9.719.1.30.11.1.3.1" -> index="1", suffix="3"
        data = {}
        for oid_str, value in entries:
            # oid_str: "1.3.6.1.4.1.9.9.719.1.30.11.1.3.1" or "1.3.6.1.4.1.9.9.719.1.30.11.1.19.1"
            if not oid_str.startswith(base_oid.split(".")[-1]) and not oid_str.startswith("1.3.6.1.4.1.9.9.719.1.30.11.1"):
                continue
            # Remove common prefix
            full_oid = "1.3.6.1.4.1.9.9.719.1.30.11.1"
            if oid_str.startswith(full_oid):
                rest = oid_str[len(full_oid):]
                if rest.startswith("."):
                    rest = rest[1:]
                # Split to get index and suffix
                parts = rest.split(".")
                if len(parts) < 2:
                    continue
                index = parts[0]
                suffix = parts[1]
                if index not in data:
                    data[index] = {}
                data[index][suffix] = value
        # Now assemble records
        records = []
        for index, fields in data.items():
            rn = fields.get("3", "")
            serial = fields.get("19", "")
            memtype = fields.get("23", "")
            capacity = fields.get("6", "")
            oper = fields.get("14", "")
            presence = fields.get("17", "")
            dn = fields.get("2", "")
            records.append((rn, serial, memtype, capacity, oper, presence, dn))
        return records

    # Walk all needed OIDs at once to reconstruct rows
    oids_to_walk = [
        ".1.3.6.1.4.1.9.9.719.1.30.11.1.3",   # rn
        ".1.3.6.1.4.1.9.9.719.1.30.11.1.19",  # serial
        ".1.3.6.1.4.1.9.9.719.1.30.11.1.23",  # type
        ".1.3.6.1.4.1.9.9.719.1.30.11.1.6",   # capacity
        ".1.3.6.1.4.1.9.9.719.1.30.11.1.14",  # operability
        ".1.3.6.1.4.1.9.9.719.1.30.11.1.17",  # presence
        ".1.3.6.1.4.1.9.9.719.1.30.11.1.2",   # dn
    ]
    # Perform a single snmpwalk for each OID and combine results
    # Since Starlark ctx.run cannot merge multiple OID results easily,
    # we walk each OID separately and reconstruct using index
    # For simplicity and correctness, we'll use snmpwalk per OID
    all_lines = []
    for oid in oids_to_walk:
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        if res.rc != 0:
            # If one fails, skip; we'll discover no items
            all_lines = []
            break
        for line in res.stdout.splitlines():
            if line.strip():
                all_lines.append(line.strip())

    # Parse SNMP output
    records = parse_snmp_output(all_lines)

    if params.get("_discover"):
        # Discovery: yield items for non-missing equipment
        discovery_items = []
        for rn, serial, memtype, capacity, oper, presence, dn in records:
            # Skip missing presence (per source: only yield if presence != "missing")
            # Per source: presence enum "missing" has monitoring_state OK, but source code filters:
            #   if memory_module.presence is not Presence.missing
            # In our mapping: Presence.missing = "11"
            if presence == "11":
                continue
            # For discovery, we yield Service(item=rn), where rn is the relative name
            # We'll use rn as the item name
            discovery_items.append({
                "item": rn if rn else "",
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d memory modules" % len(discovery_items),
            "data": {"discovery": discovery_items},
        }

    # Check mode: item is given
    item = params.get("item", "")
    # Find record with matching rn (item)
    record = None
    for rn, serial, memtype, capacity, oper, presence, dn in records:
        if rn == item:
            record = (rn, serial, memtype, capacity, oper, presence, dn)
            break

    if record == None:
        return {
            "changed": False,
            "msg": "memory module not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rn, serial, memtype, capacity, oper, presence, dn = record

    # Determine operability state
    oper_state_idx = _get_state_for_operability(oper)
    oper_name = OPERABILITY_MAP.get(oper, ("unknown", "unknown"))[1]

    # Determine presence state
    pres_state_idx = _get_state_for_presence(presence)
    pres_name = PRESENCE_MAP.get(presence, ("unknown", "unknown"))[1]

    # Determine highest state
    state_idx = max(oper_state_idx, pres_state_idx)
    state = _state_to_str(state_idx)

    # Build summary message
    memtype_name = MEMORY_TYPES.get(memtype, "unknown")
    msg = "Status: %s, Presence: %s, Type: %s, Size: %s MB, SN: %s" % (
        oper_name, pres_name, memtype_name, capacity, serial
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
