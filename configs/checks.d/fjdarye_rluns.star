# FJDARYE RLUN check - read-only Starlark translation
# No imports, no exceptions, no mutations — only discovery + check

# RLUN status mapping — third byte value -> (state, summary)
FJDARYE_RLUNS_STATUS_MAPPING = {
    "\x08": ("WARN", "RLUN is rebuilding"),
    "\x07": ("WARN", "RLUN copyback in progress"),
    "A": ("WARN", "RLUN spare is in use"),
    "B": ("OK", "RLUN is in RAID0 state"),
    "\x00": ("OK", "RLUN is in normal state"),
}

def _parse_raw_bytes(raw_str):
    # Parse escaped hex string like "\\x08\\u00A0" into bytes
    result = ""
    i = 0
    while i < len(raw_str):
        if raw_str[i] == "\\" and i + 3 < len(raw_str) and raw_str[i+1:i+3] == "x":
            hex_part = raw_str[i+3:i+5]
            if hex_part[0].isdigit() or (hex_part[0].lower() in "abcdef") and hex_part[1].isdigit() or (hex_part[1].lower() in "abcdef"):
                val = int(hex_part, 16)
                result = result + chr(val)
                i = i + 5
            else:
                result = result + raw_str[i]
                i = i + 1
        else:
            result = result + raw_str[i]
            i = i + 1
    return result

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk all supported device OIDs and collect RLUNs with presence flag
        supported_bases = [
            ".1.3.6.1.4.1.211.1.21.1.60.3.4.2.1",
            ".1.3.6.1.4.1.211.1.21.1.100.3.4.2.1",
            ".1.3.6.1.4.1.211.1.21.1.101.3.4.2.1",
        ]
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        rluns = []

        for base in supported_bases:
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base], mutates=False)
            if res.rc != 0:
                continue
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) != 2:
                    continue
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                if not oid_part.startswith(base):
                    continue
                index = oid_part.rsplit(".", 1)[-1]
                raw_str = ""
                if value_part.startswith("STRING: \""):
                    raw_str = value_part[8:].rstrip("\"")
                else:
                    continue
                raw_bytes = _parse_raw_bytes(raw_str)
                if len(raw_bytes) >= 4 and ord(raw_bytes[3]) == 160:
                    rluns.append({"item": index, "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d RLUNs" % len(rluns),
            "data": {"discovery": rluns},
        }

    # Check mode — single item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    supported_bases = [
        ".1.3.6.1.4.1.211.1.21.1.60.3.4.2.1",
        ".1.3.6.1.4.1.211.1.21.1.100.3.4.2.1",
        ".1.3.6.1.4.1.211.1.21.1.101.3.4.2.1",
    ]
    raw_bytes = ""

    for base in supported_bases:
        oid = base + "." + str(item)
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        if res.rc != 0:
            continue
        line = res.stdout.strip()
        if not line:
            continue
        eq_idx = line.find(" = ")
        if eq_idx == -1:
            continue
        value_part = line[eq_idx + 3:].strip()
        if value_part.startswith("STRING: \""):
            raw_str = value_part[8:].rstrip("\"")
            raw_bytes = _parse_raw_bytes(raw_str)
            break

    if not raw_bytes:
        return {
            "changed": False,
            "msg": "RLUN %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Presence check: 4th byte must be "\u00A0" (decimal 160)
    if len(raw_bytes) < 4 or ord(raw_bytes[3]) != 160:
        return {
            "changed": False,
            "msg": "RLUN %s is not present" % item,
            "data": {"state": "CRIT", "metrics": {}, "details": ""},
        }

    # Status from third byte (index 2)
    third_byte = raw_bytes[2] if len(raw_bytes) > 2 else "\x00"
    state_summary = FJDARYE_RLUNS_STATUS_MAPPING.get(third_byte, ("CRIT", "RLUN in unknown state"))
    state, summary = state_summary

    return {
        "changed": False,
        "msg": "RLUN %s: %s" % (item, summary),
        "data": {"state": state, "metrics": {}, "details": ""},
    }