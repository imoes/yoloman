# Starlark check module: datapower_pdrive (Checkmk check translation)
# Monitors physical drives on IBM DataPower appliances via SNMP.

def main(ctx, params):
    # --- Discovery mode: enumerate physical drives on the DataPower box ---
    if params.get("_discover"):
        # The item name is "<controller>-<device>" built from the SNMP table.
        # We discover by walking the drive-status OID and yielding an item per row
        # whose status is not "12" (Undefined).
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        if not params.get("host"):
            # No host specified — cannot reach the appliance.
            return {"changed": False, "msg": "no host configured",
                    "data": {"discovery": []}}

        # Probe the real thing: the DataPower pdrive table status OID suffix .7
        walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                        host, ".1.3.6.1.4.1.14685.3.1.260.1.7"],
                       mutates=False)
        if walk.rc == 127:
            # snmpwalk not installed — product absent on this host.
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"discovery": []}}
        if walk.rc != 0:
            # No response / not a DataPower — discovery returns empty.
            return {"changed": False, "msg": "no DataPower pdrive data",
                    "data": {"discovery": []}}

        col_base = ".1.3.6.1.4.1.14685.3.1.260.1.7"
        items = []
        seen = set()
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip()
            prefix = col_base + "."
            if not oid.startswith(prefix):
                continue
            index = oid[len(prefix):]
            if val == "12":
                continue
            # We need controller and device to build the item; fetch by index.
            ctrl_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                                host, ".1.3.6.1.4.1.14685.3.1.260.1.1." + index],
                               mutates=False)
            dev_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                               host, ".1.3.6.1.4.1.14685.3.1.260.1.2." + index],
                              mutates=False)
            if ctrl_res.rc != 0 or dev_res.rc != 0:
                continue
            controller = ctrl_res.stdout.strip()
            device = dev_res.stdout.strip()
            if not controller or not device:
                continue
            item = controller + "-" + device
            if item in seen:
                continue
            seen.add(item)
            items.append({"item": item, "params": {}, "metrics": []})

        return {"changed": False,
                "msg": "discovered %d physical drives" % len(items),
                "data": {"discovery": items}}

    # --- Check mode: grade a single physical drive ---
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if not host:
        return {"changed": False, "msg": "no host configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Walk all nine columns of the pdrive table to find the row matching our item.
    cols = {
        "1": {"1": "controller"},
        "2": {"2": "device"},
        "4": {"3": "ldrive"},
        "6": {"4": "position"},
        "7": {"5": "status"},
        "8": {"6": "progress"},
        "14": {"7": "vendor"},
        "15": {"8": "product"},
        "18": {"9": "fail"},
    }
    # base OIDs per column (suffix after the table base .1.3.6.1.4.1.14685.3.1.260.1)
    table_base = ".1.3.6.1.4.1.14685.3.1.260.1"
    col_oids = ["1", "2", "4", "6", "7", "8", "14", "15", "18"]

    rows = {}
    indices = {}

    for c in col_oids:
        full = table_base + "." + c
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                       host, full], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if res.rc != 0:
            return {"changed": False,
                    "msg": "no DataPower pdrive data for host " + str(host),
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        prefix = full + "."
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip()
            if not oid.startswith(prefix):
                continue
            index = oid[len(prefix):]
            if index not in rows:
                rows[index] = {}
                indices[index] = 0
            rows[index][c] = val
            indices[index] = 1

    target_controller = None
    target_device = "-" + item.split("-", 1)[1] if "-" in item else ""
    # Build controller-device from item: item = controller-device
    parts = item.split("-", 1)
    if len(parts) < 2:
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    want_controller = parts[0]
    want_device = parts[1]

    found = None
    for idx, row in rows.items():
        if row.get("1") == want_controller and row.get("2") == want_device:
            found = row
            break

    if found == None:
        return {"changed": False,
                "msg": "physical drive not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    datapower_pdrive_status = {
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
    datapower_pdrive_position = {
        "1": "HDD 0",
        "2": "HDD 1",
        "3": "HDD 2",
        "4": "HDD 3",
        "5": "undefined",
    }

    status = found.get("7", "12")
    st_pair = datapower_pdrive_status.get(status)
    if st_pair == None:
        state = "WARN"
        state_txt = "Unknown status: " + str(status)
    else:
        state = st_pair[0]
        state_txt = st_pair[1]

    position = found.get("6", "5")
    position_txt = datapower_pdrive_position.get(position, "undefined")

    progress = found.get("8", "0")
    if progress != None and progress != "" and progress != "0":
        progress_txt = " - Progress: %s%%" % progress
    else:
        progress_txt = ""

    ldrive = found.get("3", "")
    vendor = found.get("14", "")
    product = found.get("15", "")
    member_of_ldrive = want_controller + "-" + ldrive if ldrive != "" else ""

    infotext = "%s%s, Position: %s, Logical Drive: %s, Product: %s %s" % (
        state_txt, progress_txt, position_txt, member_of_ldrive,
        vendor, product)

    fail_val = found.get("18", "")
    if fail_val and fail_val != "0":
        # Disk reports a failure — escalate to CRIT regardless of status.
        msg = "disk reports failure"
        details = infotext + " - " + msg
        return {"changed": False, "msg": infotext,
                "data": {"state": "CRIT", "metrics": {}, "details": details}}

    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": {}, "details": infotext}}