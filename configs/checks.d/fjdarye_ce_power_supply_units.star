# ===== Starlark check module for Fujitsu CPSU monitoring =====
# Translate Check: checkmk.fjdarye_ce_power_supply_units
# Read-only SNMP check: gather power supply unit status via SNMP and report OK/WARN/CRIT

# SNMP base OIDs for supported Fujitsu devices
FJDARYE_SUPPORTED_DEVICES = [
    ".1.3.6.1.4.1.211.1.21.1.100",  # fjdarye100
    ".1.3.6.1.4.1.211.1.21.1.150",  # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153",  # fjdarye600
]

# Status mapping (string keys) to Checkmk states
FJDARYE_ITEM_STATUS = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}


def main(ctx, params):
    if params.get("_discover"):
        # ===== DISCOVERY MODE: walk all supported base OIDs for CPSU table =====
        # Table base: <device_oid>.2.13.2.1, OIDs: [1=index, 3=status]
        out = []
        for base in FJDARYE_SUPPORTED_DEVICES:
            table_base = base + ".2.13.2.1"
            res = ctx.run(
                ["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                 params.get("host", "localhost"), table_base],
                mutates=False
            )
            if res.rc != 0:
                continue  # skip devices that don't respond
            lines = res.stdout.splitlines()
            current_idx = None
            for line in lines:
                parts = line.strip().split(" = ")
                if len(parts) < 2:
                    continue
                oid_val = parts[1].strip()
                # Parse "INTEGER: <value>" or similar format
                if ":" in oid_val:
                    value = oid_val.split(":", 1)[1].strip()
                else:
                    value = oid_val
                # We need index (first OID leaf) and status (third leaf)
                # snmpwalk returns lines like:
                #   <table_base>.1.1 = INTEGER: <index>
                #   <table_base>.1.3 = INTEGER: <status>
                # So group by base index
                # Extract <base>.<idx>.<leaf> => split on '.' and get parts
                # oid path before leaf: e.g., <table_base>.1.1 -> <table_base>.1
                if not line.startswith(table_base):
                    continue
                suffix = line[len(table_base):].strip()
                if suffix.startswith("."):
                    suffix = suffix[1:]
                parts_suffix = suffix.split(".")
                if len(parts_suffix) < 2:
                    continue
                idx = parts_suffix[0]  # e.g., "1"
                leaf = parts_suffix[1]  # "1" or "3"
                if leaf == "1":
                    # index line
                    current_idx = idx
                    current_status = None
                elif leaf == "3" and current_idx == idx:
                    # status line for this idx
                    status_val = int(value) if value.isdigit() else 4  # default Invalid
                    current_status = str(status_val)
                    if current_status != "4":
                        out.append({
                            "item": current_idx,
                            "params": {},
                            "metrics": []
                        })
        return {
            "changed": False,
            "msg": "discovered %d power supply units" % len(out),
            "data": {"discovery": out}
        }

    # ===== CHECK MODE: examine one item =====
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Walk all supported devices to find this item
    found = False
    status_val = None
    for base in FJDARYE_SUPPORTED_DEVICES:
        if found:
            break
        table_base = base + ".2.13.2.1"
        # Get both index and status for the specific item
        # Use snmpget for exact OIDs: <table_base>.<item>.1 and <table_base>.<item>.3
        idx_oid = table_base + "." + item + ".1"
        status_oid = table_base + "." + item + ".3"
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
             params.get("host", "localhost"), idx_oid, status_oid],
            mutates=False
        )
        if res.rc != 0:
            continue  # device not responding

        lines = res.stdout.splitlines()
        idx_value = None
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_str = parts[0].strip()
            val_str = parts[1].strip()
            if ":" in val_str:
                val_str = val_str.split(":", 1)[1].strip()
            if oid_str.endswith(".1"):
                idx_value = int(val_str) if val_str.isdigit() else None
            elif oid_str.endswith(".3"):
                status_val = int(val_str) if val_str.isdigit() else 4  # Invalid as fallback
        if idx_value != None and idx_value == int(item):
            found = True
            break

    if not found or status_val == None:
        return {
            "changed": False,
            "msg": "item %s not found or invalid" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status_str = str(status_val)
    state, summary = FJDARYE_ITEM_STATUS.get(status_str, ("UNKNOWN", "Unknown status " + status_str))
    return {
        "changed": False,
        "msg": "Status: " + summary,
        "data": {"state": state, "metrics": {}, "details": summary}
    }
