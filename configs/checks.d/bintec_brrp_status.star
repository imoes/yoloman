# SNMP OIDs for bintec_brrp_status
_BRRP_BASE_OID = ".1.3.6.1.4.1.272.4.40.1.1"
_BRRP_ID_END_OID = _BRRP_BASE_OID + ".1"  # OIDEnd()
_BRRP_STATUS_OID = _BRRP_BASE_OID + ".4"

# Status mapping (from source: "1"=init->WARN, "2"=backup->OK, "3"=master->OK)
_STATUS_MAP = {
    "1": ("initialize", "WARN"),
    "2": ("backup", "OK"),
    "3": ("master", "OK"),
}


def _compose_item(brrp_id):
    # Strip everything after the first dot (e.g., "1.2.3" -> "1")
    dot_index = brrp_id.find(".")
    if dot_index == -1:
        return brrp_id
    return brrp_id[:dot_index]


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk the BRRP section
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            _BRRP_BASE_OID
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        # Parse snmpwalk output: "<OID> = STRING: <value>" or similar
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Extract OID end and value: "oid.1 = STRING: 1" -> brrp_id="1"
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            value_str = parts[1].strip()
            # Get OID end (e.g., ".1.3.6.1.4.1.272.4.40.1.1.1.1" -> "1.1")
            # The last component after the base is the index
            if not oid_val.startswith(_BRRP_BASE_OID + "."):
                continue
            # Split base and remainder: ".1.3.6.1.4.1.272.4.40.1.1.1" -> "1"
            remainder = oid_val[len(_BRRP_BASE_OID) + 1:]
            brrp_id = remainder.rstrip(".0")  # strip trailing ".0" if present
            if not brrp_id:
                continue
            # Extract status from value string: "STRING: 1" -> "1"
            if value_str.startswith("STRING: "):
                status = value_str[8:].strip()
            else:
                # Some agents return bare string: "1"
                status = value_str.strip(' "')
            item = _compose_item(brrp_id)
            items.append({
                "item": item,
                "params": {},
                "metrics": []
            })

        return {
            "changed": False,
            "msg": "discovered %d BRRP instances" % len(items),
            "data": {"discovery": items},
        }

    # Check mode: find the requested item
    item = params.get("item", "")
    # Reuse same walk data (no extra SNMP calls needed)
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        _BRRP_BASE_OID
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse entries
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_val = parts[0].strip()
        value_str = parts[1].strip()
        if not oid_val.startswith(_BRRP_BASE_OID + "."):
            continue
        remainder = oid_val[len(_BRRP_BASE_OID) + 1:]
        brrp_id = remainder.rstrip(".0")
        if not brrp_id:
            continue
        # Extract status
        if value_str.startswith("STRING: "):
            status = value_str[8:].strip()
        else:
            status = value_str.strip(' "')
        brrp_id_composed = _compose_item(brrp_id)
        if brrp_id_composed == item:
            status_str = str(status)
            if status_str in _STATUS_MAP:
                desc, state_key = _STATUS_MAP[status_str]
                return {
                    "changed": False,
                    "msg": "Status for %s is %s" % (item, desc),
                    "data": {
                        "state": state_key,
                        "metrics": {},
                        "details": "",
                    },
                }
            else:
                return {
                    "changed": False,
                    "msg": "Status for %s is at unknown value %s" % (item, status),
                    "data": {
                        "state": "UNKNOWN",
                        "metrics": {},
                        "details": "",
                    },
                }

    # Item not found
    return {
        "changed": False,
        "msg": "Status for %s not found" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }
