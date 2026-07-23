# ===== Checkmk check: datapower_pdrive (translated to Starlark) =====
# This check monitors physical drive status via SNMP on DataPower devices.
# It reads the same SNMP OIDs as the original Checkmk plugin:
#   .1.3.6.1.4.1.14685.3.1.260.1.{1,2,4,6,7,8,14,15,18}
#   = controller, device, ldrive, position, status, progress, vendor, product, fail

# Status mapping: key -> (State, text)
# Note: "12" (Undefined) is skipped in discovery per the original logic
DATAPOW_PDRIVE_STATUS = {
    "1": ("OK", "Unconfigured/Good"),
    "2": ("OK", "Unconfigured/Good/Foreign"),
    "3": ("WARN", "Unconfigured/Bad"),
    "4": ("WARN", "Unconfigured/Bad/Foreign"),
    "5": ("OK", "Hot spare"),
    "6": ("WARN", "Offline"),
    "7": ("CRIT", "Failed"),
    "8": ("WARN", "Rebuilding"),
    "9": ("OK", "Online"),
    "10": ("WARN", "Copyback"),
    "11": ("WARN", "System"),
    "12": ("WARN", "Undefined"),
}

# Fail mapping: key -> text
DATAPOW_PDRIVE_FAIL = {
    "1": "disk reports failure",
    "2": "disk reports no failure",
}

# Position mapping: key -> text
DATAPOW_PDRIVE_POSITION = {
    "1": "HDD 0",
    "2": "HDD 1",
    "3": "HDD 2",
    "4": "HDD 3",
    "5": "undefined",
}

# SNMP base OID and host/community params
SNMP_BASE_OID = ".1.3.6.1.4.1.14685.3.1.260.1"


def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk the pdrive OID and yield discovered items
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), SNMP_BASE_OID
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        # Parse snmpwalk output lines: "<OID> = <TYPE>: <value>"
        # Group into rows by extracting the index suffix
        rows = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Format: ".1.3.6.1.4.1.14685.3.1.260.1.<index>.<column> = STRING: <value>"
            # Split at first space: oid_part = ".1.3.6.1.4.1.14685.3.1.260.1.<index>.<column>"
            parts = line.strip().split(" ", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()
            # Remove leading .1.3.6.1.4.1.14685.3.1.260.1. and split index/column
            rest = oid_full[len(SNMP_BASE_OID) + 1:]
            if "." not in rest:
                continue
            idx_col = rest.split(".", 1)
            if len(idx_col) != 2:
                continue
            idx = idx_col[0]
            col = idx_col[1]
            val = value.strip('"') if value.startswith('"') else value
            rows.append({"index": idx, "column": col, "value": val})

        # Map columns: 1->controller, 2->device, 4->ldrive, 6->position,
        #              7->status, 8->progress, 14->vendor, 15->product, 18->fail
        drive_data = {}
        for row in rows:
            idx = row["index"]
            col = row["column"]
            val = row["value"]
            if idx not in drive_data:
                drive_data[idx] = {}
            drive_data[idx][col] = val

        # Assemble items (skip status "12")
        discovery = []
        for idx in sorted(drive_data.keys()):
            row = drive_data[idx]
            controller = row.get("1", "")
            device = row.get("2", "")
            status = row.get("7", "")
            if status == "12":
                continue  # skip undefined drives per discovery logic
            item = controller + "-" + device
            if item:
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d physical drives" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Normal check mode: examine one item
    item = params.get("item", "")
    # Build item prefix (e.g., "1-2") to match discovery
    if item == "":
        fail("item is required for check mode")

    # Fetch all columns for all drives in one walk
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), SNMP_BASE_OID
    ], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed: " + res.stderr)

    # Parse into rows
    rows = []
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()
        rest = oid_full[len(SNMP_BASE_OID) + 1:]
        if "." not in rest:
            continue
        idx_col = rest.split(".", 1)
        if len(idx_col) != 2:
            continue
        idx = idx_col[0]
        col = idx_col[1]
        val = value.strip('"') if value.startswith('"') else value
        rows.append({"index": idx, "column": col, "value": val})

    # Group rows by index
    drive_data = {}
    for row in rows:
        idx = row["index"]
        col = row["column"]
        val = row["value"]
        if idx not in drive_data:
            drive_data[idx] = {}
        drive_data[idx][col] = val

    # Find matching drive
    for idx in drive_data.keys():
        row = drive_data[idx]
        controller = row.get("1", "")
        device = row.get("2", "")
        ldrive = row.get("4", "")
        position = row.get("6", "")
        status = row.get("7", "")
        progress = row.get("8", "")
        vendor = row.get("14", "")
        product = row.get("15", "")
        fail = row.get("18", "")

        if item == controller + "-" + device:
            # Determine state and text
            state_txt = "Undefined"
            state = "UNKNOWN"
            if status in DATAPOW_PDRIVE_STATUS:
                state, state_txt = DATAPOW_PDRIVE_STATUS[status]

            # Progress
            progress_txt = ""
            if progress and progress.isdigit():
                p_val = int(progress)
                if p_val != 0:
                    progress_txt = " - Progress: %d%%" % p_val

            # Position and logical drive
            position_txt = DATAPOW_PDRIVE_POSITION.get(position, "undefined")
            member_of_ldrive = controller + "-" + ldrive if ldrive else ""

            # Build info text
            infotext = state_txt + progress_txt + ", Position: " + position_txt + ", Logical Drive: " + member_of_ldrive + ", Product: " + vendor + " " + product

            # Build result dict
            result = {
                "changed": False,
                "msg": infotext,
                "data": {
                    "state": state,
                    "metrics": {},
                    "details": "",
                },
            }

            # Add fail status if present
            if fail and fail in DATAPOW_PDRIVE_FAIL:
                result["msg"] = infotext + ", " + DATAPOW_PDRIVE_FAIL[fail]

            return result

    # Item not found
    fail("no such physical drive: " + item)
