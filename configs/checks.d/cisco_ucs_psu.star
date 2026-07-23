# ===== Starlark translation of checkmk.cisco_ucs_psu =====
# Read-only SNMP check for Cisco UCS PSU modules via snmpwalk.
# No try/except allowed — guard before risky operations instead.

# SNMP OID mappings (from Checkmk source)
PSU_OID_BASE = ".1.3.6.1.4.1.9.9.719.1.15.56.1"
PSU_DN_OID = PSU_OID_BASE + ".2"
PSU_OPERABILITY_OID = PSU_OID_BASE + ".8"
PSU_SERIAL_OID = PSU_OID_BASE + ".13"
PSU_MODEL_OID = PSU_OID_BASE + ".6"

# SNMP host/community params (checkmk expects these)
# Defaults: host="localhost", community="public"
# Host is optional in params — default to localhost if missing.

# Operability enum to monitoring state mapping (from lib_ucs)
OPERABILITY_STATE = {
    "0": "CRIT",  # unknown
    "1": "OK",    # operable
    "2": "CRIT",  # inoperable
    "3": "CRIT",  # degraded
    "4": "WARN",  # poweredOff
    "5": "CRIT",  # powerProblem
    "6": "OK",    # removed
    "7": "CRIT",  # voltageProblem
    "8": "CRIT",  # thermalProblem
    "9": "WARN",  # performanceProblem
    "10": "WARN", # accessibilityProblem
    "11": "WARN", # identityUnestablishable
    "12": "CRIT", # biosPostTimeout
    "13": "WARN", # disabled
    "14": "WARN", # malformedFru
    "51": "WARN", # fabricConnProblem
    "52": "WARN", # fabricUnsupportedConn
    "81": "WARN", # config
    "82": "CRIT", # equipmentProblem
    "83": "CRIT", # decomissioning
    "84": "WARN", # chassisLimitExceeded
    "100": "WARN",# notSupported
    "101": "WARN",# discovery
    "102": "CRIT",# discoveryFailed
    "103": "WARN",# identify
    "104": "CRIT",# postFailure
    "105": "WARN",# upgradeProblem
    "106": "WARN",# peerCommProblem
    "107": "OK",  # autoUpgrade
    "108": "WARN",# linkActivateBlocked
}


def _parse_snmp_output(output):
    """Parse snmpwalk output: lines like '<OID> = <TYPE>: <value>'."""
    # We'll collect into a list of dicts: {dn, operability, serial, model}
    # Only PSU DNs are relevant; parse based on OID suffixes.
    lines = output.splitlines()
    # Pre-map OIDs by suffix for quick lookup
    entries = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        # Format: OID = TYPE: value or OID = value
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        # Extract OID suffix
        suffix = ""
        if oid_part.startswith(PSU_OID_BASE + "."):
            suffix = oid_part[len(PSU_OID_BASE + "."):]
        else:
            continue
        # Parse value (strip TYPE prefix if present, e.g. "STRING:" or "INTEGER:")
        if ":" in val_part:
            val = val_part.split(":", 1)[1].strip().strip('"')
        else:
            val = val_part
        # We expect entries keyed by DN (e.g. "sys/chassis-1/psu-1")
        # Extract DN from OID: suffixes are 2,8,13,6 — but the base is fixed
        # Instead, we group by OID base and collect per-DN.
        # Simpler: extract DN from OID suffix '2' — that's the DN itself (string)
        if suffix == "2":
            # DN is the value
            dn = val
            if dn not in entries:
                entries[dn] = {"dn": dn, "operability": "", "serial": "", "model": ""}
            # Fill in other fields as they appear
        elif suffix in ["8", "13", "6"]:
            # Find entry by OID's DN — snmpwalk yields OID = value with same base+DN
            # We need to recompute DN: OID is base.suffix.*.dn_part
            # Actually, snmpwalk yields full OID; parse the last component as instance.
            # Simpler heuristic: group by line order? No — we use OID parsing.
            # snmpwalk line format: OID = value; OID is full.
            # OID is PSU_OID_BASE + "." + suffix + "." + instance
            # instance is the DN (e.g. "1" for first PSU), but Checkmk uses full DN path.
            # From source: `name.split("/")[2:]` — so name is like "sys/chassis-1/psu-1".
            # We'll parse the DN from OID: the OID suffix includes instance number.
            # But we don't have full OID parsing here — snmpwalk output includes the full OID.
            # Let's parse: for suffix 2, the DN is the value. For others, we need the same DN key.
            # Problem: we don't have DN key for suffix != 2 in this naive loop.
            # Fix: parse the OID fully — extract the instance part.
            # Since snmpwalk yields full OID, we can do:
            # OID = PSU_OID_BASE + "." + suffix + "." + dn_suffix
            # But that's not reliable — Checkmk uses the full DN as instance (e.g. "1" or "sys/chassis-1/psu-1").
            # Actually, Checkmk's SNMP tree fetch returns a flat table: base + [oids] per row.
            # So OID = base + "." + suffix, and each row is one instance — no instance index.
            # Wait, no — SNMP table rows have implicit instance index (1,2,3...) or explicit.
            # Let's re-read the Checkmk code: it uses `SNMPTree(base, oids=[...])`.
            # In practice, snmpwalk for base yields lines like:
            # .1.3.6.1.4.1.9.9.719.1.15.56.1.2.1 = STRING: "sys/chassis-1/psu-1"
            # .1.3.6.1.4.1.9.9.719.1.15.56.1.8.1 = STRING: "operable"
            # .1.3.6.1.4.1.9.9.719.1.15.56.1.13.1 = STRING: "XXX"
            # .1.3.6.1.4.1.9.9.719.1.15.56.1.6.1 = STRING: "XXX"
            # So the instance is the last numeric suffix (e.g. ".1").
            # We'll group by that instance suffix.
            if suffix == "8":
                # Parse instance suffix: OID ends with ".8.<instance>"
                # Actually, OID is PSU_OID_BASE + ".8.<instance>", but snmpwalk output has full OID.
                # Let's parse: find last '.' in suffix — but suffix is "8" here.
                # Better: parse the full OID part before '='.
                full_oid = oid_part
                if not full_oid.startswith(PSU_OID_BASE):
                    continue
                # Extract instance: everything after PSU_OID_BASE + "." + suffix + "."
                rest = full_oid[len(PSU_OID_BASE) + 1 + len(suffix) + 1:]
                if rest.isdigit():
                    instance = rest
                else:
                    # Fallback: assume instance=1 if not numeric? No — Checkmk expects numeric instance.
                    # But real snmpwalk may have strings? No — Cisco UCS PSU table has integer instances.
                    instance = "1"
                # Find or create entry
                if instance not in entries:
                    entries[instance] = {"instance": instance, "operability": "", "serial": "", "model": ""}
                entries[instance]["operability"] = val
            elif suffix == "13":
                full_oid = oid_part
                rest = full_oid[len(PSU_OID_BASE) + 1 + len(suffix) + 1:]
                if rest.isdigit():
                    instance = rest
                else:
                    instance = "1"
                if instance not in entries:
                    entries[instance] = {"instance": instance, "operability": "", "serial": "", "model": ""}
                entries[instance]["serial"] = val
            elif suffix == "6":
                full_oid = oid_part
                rest = full_oid[len(PSU_OID_BASE) + 1 + len(suffix) + 1:]
                if rest.isdigit():
                    instance = rest
                else:
                    instance = "1"
                if instance not in entries:
                    entries[instance] = {"instance": instance, "operability": "", "serial": "", "model": ""}
                entries[instance]["model"] = val
    # Now extract entries: for each instance, build PSUModule-style info
    result = {}
    for inst, data in entries.items():
        dn = data.get("dn", "sys/chassis-1/psu-" + str(inst))
        # But Checkmk uses dn as key, not instance. Reconcile:
        # From Checkmk: `name` is the DN (cucsEquipmentPsuDn), and instance is extracted as name.split("/")[2:].
        # So key should be the DN.
        # Our entries dict is keyed by instance, but we can derive DN as "sys/chassis-X/psu-Y".
        # Actually, snmpwalk yields the DN in OID suffix 2 — let's fix parsing.
        pass
    # Correct parsing: re-do.
    # We'll parse lines again, this time extracting DN and instance separately.
    return _parse_snmp_output_fixed(output)


def _parse_snmp_output_fixed(output):
    # Parse SNMP table where base OID is fixed, and instance is last segment.
    # Format: .1.3.6.1.4.1.9.9.719.1.15.56.1.2.1 = STRING: "sys/chassis-1/psu-1"
    # So instance is the last number after PSU_OID_BASE + "." + suffix.
    lines = output.splitlines()
    entries = {}
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        full_oid = parts[0].strip()
        val = parts[1].strip()
        if ":" in val:
            val = val.split(":", 1)[1].strip().strip('"')
        # Only process OIDs under our base
        if not full_oid.startswith(PSU_OID_BASE + "."):
            continue
        # Extract suffix (number after base)
        rest_oid = full_oid[len(PSU_OID_BASE) + 1:]
        dot_pos = rest_oid.find(".")
        if dot_pos <= 0:
            continue
        suffix = rest_oid[:dot_pos]
        instance = rest_oid[dot_pos + 1:]
        # We only care about suffix 2 (DN), 8, 13, 6
        if suffix not in ["2", "8", "13", "6"]:
            continue
        # DN key is value for suffix 2, else derive from instance
        if suffix == "2":
            dn = val
            if dn not in entries:
                entries[dn] = {"dn": dn, "operability": "", "serial": "", "model": ""}
        elif suffix == "8":
            if instance in entries:
                entries[instance]["operability"] = val
            else:
                # Derive DN from instance (Cisco UCS PSU instances are 1,2,...)
                dn = "sys/chassis-1/psu-" + str(instance)
                if dn not in entries:
                    entries[dn] = {"dn": dn, "operability": "", "serial": "", "model": ""}
                entries[dn]["operability"] = val
        elif suffix == "13":
            if instance in entries:
                entries[instance]["serial"] = val
            else:
                dn = "sys/chassis-1/psu-" + str(instance)
                if dn not in entries:
                    entries[dn] = {"dn": dn, "operability": "", "serial": "", "model": ""}
                entries[dn]["serial"] = val
        elif suffix == "6":
            if instance in entries:
                entries[instance]["model"] = val
            else:
                dn = "sys/chassis-1/psu-" + str(instance)
                if dn not in entries:
                    entries[dn] = {"dn": dn, "operability": "", "serial": "", "model": ""}
                entries[dn]["model"] = val
    # Return dict keyed by DN
    return entries


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, PSU_OID_BASE
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": []}}
        
        psu_map = _parse_snmp_output_fixed(res.stdout)
        discovery = []
        for dn in psu_map:
            # Extract item name from DN — Checkmk uses "sys/chassis-1/psu-1" as item
            item = dn
            discovery.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d PSUs" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode for one item
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, PSU_OID_BASE
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    psu_map = _parse_snmp_output_fixed(res.stdout)
    psu = psu_map.get(item)
    if psu == None or len(psu) == 0:
        return {"changed": False, "msg": "PSU not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    operability = psu.get("operability", "0")
    # Map operability to state (from OPERABILITY_STATE)
    state_str = OPERABILITY_STATE.get(operability, "CRIT")
    
    model = psu.get("model", "")
    serial = psu.get("serial", "")
    
    msg = "Status: %s, Model: %s, SN: %s" % (
        operability if operability in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "51", "52", "81", "82", "83", "84", "100", "101", "102", "103", "104", "105", "106", "107", "108"] else "unknown",
        model,
        serial
    )
    
    return {"changed": False, "msg": msg,
            "data": {"state": state_str, "metrics": {}, "details": ""}}
