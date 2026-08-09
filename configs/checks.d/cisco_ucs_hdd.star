def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.9.9.719.1.45.4.1"
        ], mutates=False)
        hdds = {}
        for line in res.stdout.splitlines():
            if "=" not in line:
                continue
            parts = line.strip().split(" = ")
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            if not oid_part.startswith(".1.3.6.1.4.1.9.9.719.1.45.4.1."):
                continue
            suffix = oid_part[len(".1.3.6.1.4.1.9.9.719.1.45.4.1."):]
            if "." not in suffix:
                continue
            dot_pos = suffix.find(".")
            oid_num = suffix[:dot_pos]
            idx = suffix[dot_pos + 1:]
            if oid_num not in ("6", "7", "9", "12", "13", "14", "18"):
                continue
            v = val_part.strip('"')
            if idx not in hdds:
                hdds[idx] = {}
            hdds[idx][oid_num] = v

        out = []
        for idx, data in hdds.items():
            if not (("6" in data) and ("7" in data) and ("9" in data) and ("12" in data) and ("13" in data) and ("14" in data) and ("18" in data)):
                continue
            disk_id = data["6"]
            r_operability = data["9"]
            if r_operability == "6":
                continue
            out.append({
                "item": disk_id,
                "params": {},
                "metrics": []
            })

        return {
            "changed": False,
            "msg": "discovered %d HDDs" % len(out),
            "data": {"discovery": out}
        }

    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.9.9.719.1.45.4.1"
    ], mutates=False)

    hdds = {}
    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.strip().split(" = ")
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        if not oid_part.startswith(".1.3.6.1.4.1.9.9.719.1.45.4.1."):
            continue
        suffix = oid_part[len(".1.3.6.1.4.1.9.9.719.1.45.4.1."):]
        if "." not in suffix:
            continue
        dot_pos = suffix.find(".")
        oid_num = suffix[:dot_pos]
        idx = suffix[dot_pos + 1:]
        if oid_num not in ("6", "7", "9", "12", "13", "14", "18"):
            continue
        v = val_part.strip('"')
        if idx not in hdds:
            hdds[idx] = {}
        hdds[idx][oid_num] = v

    hdd_data = None
    for idx, data in hdds.items():
        if not (("6" in data) and ("7" in data) and ("9" in data) and ("12" in data) and ("13" in data) and ("14" in data) and ("18" in data)):
            continue
        if data["6"] == item:
            hdd_data = data
            break

    if hdd_data == None:
        return {
            "changed": False,
            "msg": "HDD %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    MAP_OPERABILITY = {
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
        "108": (1, "linkActivateBlocked")
    }

    disk_id = hdd_data["6"]
    r_operability = hdd_data["9"]
    drive_status_str = hdd_data["18"]
    model = hdd_data["7"]
    vendor = hdd_data["14"]
    serial = hdd_data["12"]
    r_size = hdd_data["13"]
    size_bytes = int(r_size) * 1024 * 1024 if r_size.isdigit() else 0

    state_map = MAP_OPERABILITY.get(r_operability, (2, "unknown"))
    state_code = state_map[0]
    operability = state_map[1]

    state_str = "OK"
    if state_code == 0:
        state_str = "OK"
    elif state_code == 1:
        state_str = "WARN"
    else:
        state_str = "CRIT"

    if drive_status_str == "3" or drive_status_str == "4":
        state_str = "OK"
        summary = "Status: %s (hot spare)" % operability
    else:
        summary = "Status: %s" % operability

    size_human = "%d MB" % (size_bytes // (1024 * 1024))

    return {
        "changed": False,
        "msg": "%s, Size: %s, Model: %s, Vendor: %s, Serial: %s" % (
            summary, size_human, model, vendor, serial
        ),
        "data": {
            "state": state_str,
            "metrics": {
                "size": size_bytes
            },
            "details": ""
        }
    }