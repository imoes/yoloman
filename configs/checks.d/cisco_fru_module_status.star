def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk ENTITY-MIB entPhysicalClass and CISCO-ENTITY-FRU-CONTROL-MIB cefcModuleOperStatus
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.2.1.47.1.1.1.1.5"
        ], mutates=False)
        # Map OID index -> module index for modules (class == 10)
        module_indices = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_str = parts[0]
            val = parts[1].strip()
            if val != "10":
                continue
            # Extract index from OID: .1.3.6.1.2.1.47.1.1.1.1.5.<index>
            idx = oid_str.rsplit(".", 1)[-1]
            module_indices.append(idx)

        # Now fetch cefcModuleOperStatus for those modules
        status_map = {}
        for idx in module_indices:
            oid = ".1.3.6.1.4.1.9.9.117.1.2.1.1.2." + idx
            res = ctx.run([
                "snmpget", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), oid
            ], mutates=False)
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) < 2:
                    continue
                val = parts[1].strip()
                if val.isdigit():
                    status_map[idx] = val
                break

        # Fetch module names (entPhysicalName) for modules only
        names = {}
        for idx in module_indices:
            oid = ".1.3.6.1.2.1.47.1.1.1.1.7." + idx
            res = ctx.run([
                "snmpget", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), oid
            ], mutates=False)
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) < 2:
                    continue
                val = parts[1].strip()
                # Strip leading/trailing quotes if present
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                names[idx] = val
                break

        # Build discovery list
        discovered = []
        for idx in module_indices:
            if idx in status_map:
                discovered.append({
                    "item": idx,
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d FRU modules" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode: item is module index
    item = params.get("item", "")
    if not item.isdigit():
        return {
            "changed": False,
            "msg": "invalid module index",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch module status
    status_oid = ".1.3.6.1.4.1.9.9.117.1.2.1.1.2." + item
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), status_oid
    ], mutates=False)
    status = None
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        val = parts[1].strip()
        if val.isdigit():
            status = val
        break

    if status == None:
        return {
            "changed": False,
            "msg": "module not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch module name
    name_oid = ".1.3.6.1.2.1.47.1.1.1.1.7." + item
    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), name_oid
    ], mutates=False)
    name = ""
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        val = parts[1].strip()
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        name = val
        break

    # Map status to state and label
    STATE_MAP = {
        "1": ("CRIT", "unknown"),
        "2": ("OK", "OK"),
        "3": ("WARN", "disabled"),
        "4": ("WARN", "OK but diag failed"),
        "5": ("WARN", "boot"),
        "6": ("WARN", "self test"),
        "7": ("CRIT", "failed"),
        "8": ("CRIT", "missing"),
        "9": ("CRIT", "mismatch with parent"),
        "10": ("CRIT", "mismatch config"),
        "11": ("CRIT", "diag failed"),
        "12": ("CRIT", "dormant"),
        "13": ("CRIT", "out of service (admin)"),
        "14": ("CRIT", "out of service (temperature)"),
        "15": ("CRIT", "powered down"),
        "16": ("WARN", "powered up"),
        "17": ("CRIT", "power denied"),
        "18": ("WARN", "power cycled"),
        "19": ("WARN", "OK but power over warning"),
        "20": ("WARN", "OK but power over critical"),
        "21": ("WARN", "sync in progress"),
        "22": ("WARN", "upgrading"),
        "23": ("WARN", "OK but auth failed"),
        "24": ("WARN", "minimum disruptive restart upgrade"),
        "25": ("WARN", "firmware mismatch found"),
        "26": ("WARN", "firmware download success"),
        "27": ("CRIT", "firmware download failure"),
    }

    state_label = STATE_MAP.get(status, ("UNKNOWN", "unknown"))
    state = state_label[0]
    label = state_label[1]

    # Build message
    name_part = ""
    if name:
        name_part = "[" + name + "] "
    msg = name_part + "Operational status: " + label

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
